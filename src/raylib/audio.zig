//! Audio subsystem of the raylib backend: the layered-cue sound caches
//! (base one-shots + skill/action/item layers) and the ambient-music
//! intensity stack. The backend keeps thin wrappers over `init`/`deinit`/
//! `playSounds`/`updateMusic` so the duck-typed interface main.zig drives
//! is unchanged. Layer-path building uses fixed stack buffers (paths are
//! short and bounded — no arena dependency). See DESIGN → Audio.

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");

/// Upper bound on probed music intensity layers — the shared constant lives
/// in types.zig (`types.max_music_layers`); see DESIGN → Audio (layered
/// music).
const max_music_layers = types.max_music_layers;

/// The intensity-layer fade duration (volume-lerp time constant, real
/// microseconds): aggro/death transitions crossfade instead of hard-cutting.
/// See DESIGN → Audio (layered music).
const music_fade_microseconds: u64 = 1_000_000;

/// Diagnostics sink for load-time warnings: the caller passes a function that
/// appends the (already formatted, newline-terminated) message to its log
/// — the backend wires this to its diagnostics append so the music phase-lock warning
/// reaches logs/diagnostics.txt. The context is the sink's receiver.
pub const DiagnosticsSink = *const fn (context: ?*anyopaque, message: []const u8) void;

/// One ambient-music stream layer (see `Audio.music_layers`).
/// `volume` is the lerped TIER-level volume (0..1); the music/master
/// settings scaling is applied at setMusicVolume time each frame.
const MusicLayer = struct {
    stream: rl.Music,
    data: []const u8,
    volume: f32,
};

/// The tier-level volume of music intensity layer `index` (1-based) while
/// active — descending so a full stack never drowns the base track. The
/// table covers more tiers than any realistic stem set; the last entry is
/// the floor for anything beyond. See DESIGN → Audio (layered music).
fn musicLayerVolume(layer_index: usize) f32 {
    const tier_volumes = [_]f32{ 0.8, 0.65, 0.5, 0.4, 0.3, 0.25, 0.2, 0.15 };
    return if (layer_index <= tier_volumes.len)
        tier_volumes[layer_index - 1]
    else
        tier_volumes[tier_volumes.len - 1];
}

/// Path scratch: every audio path is "assets/audio/..." + an enum tag +
/// a suffix, far below 128 bytes. Stack-allocated per call — the file
/// source only reads the slice during the call.
const path_buffer_size = 128;

pub const Audio = struct {
    allocator: std.mem.Allocator,
    /// Unified file source for audio bytes (embedded map / persistent dir).
    file_source: *const @import("../file_source.zig").FileSource,

    /// One-shot sound effects, one per `SoundId`, loaded via
    /// `loadWaveFromMemory` + `loadSoundFromWave` from the file source.
    /// Missing audio is a normal in-progress state (like missing sprites) ->
    /// cache null and skip play. See DESIGN → Audio.
    sound_cache: std.AutoHashMapUnmanaged(types.SoundId, ?rl.Sound) = .empty,
    /// Skill layer sounds (the specific half of a skill cue), keyed by
    /// `SkillId`, resolved from `assets/audio/sfx/skills/<id>_layer`. Unlike
    /// `sound_cache`, MISSES ARE NOT CACHED — a layer file dropped into
    /// the persistent dir mid-session is picked up by the next cast, no
    /// relaunch (the sound-designer iteration loop). See DESIGN → Audio
    /// (layered cues).
    skill_layer_cache: std.AutoHashMapUnmanaged(types.SkillId, ?rl.Sound) = .empty,
    /// Action layer sounds (the specific half of a button cue), keyed by
    /// `Action`, resolved from `assets/audio/sfx/buttons/<action>_layer`.
    /// Same miss-not-cached discipline as `skill_layer_cache`.
    action_layer_cache: std.AutoHashMapUnmanaged(types.Action, ?rl.Sound) = .empty,
    /// Item-action layer sounds (equip / salvage / learn_skill), keyed by
    /// `ItemActionSound`, resolved from `assets/audio/sfx/items/<tag>_layer`.
    /// Same miss-not-cached discipline as `skill_layer_cache`.
    item_layer_cache: std.AutoHashMapUnmanaged(types.ItemActionSound, ?rl.Sound) = .empty,
    /// The ambient-music stream stack: index 0 = the base track (always
    /// on), 1..N = the intensity layers (`ambient_layer_1..N` — one per
    /// active enemy, played while the projected active count >= the layer
    /// index; see DESIGN → Audio — layered music). Loaded generically at
    /// init: layers are probed until the first missing file, so new stems
    /// are a pure asset drop — the stack extends without code changes.
    /// All layers must be IDENTICAL-LENGTH, sample-aligned loops (raylib
    /// loops each stream independently — only exact-equal lengths keep
    /// them phase-locked; a mismatch is reported to the diagnostics sink at
    /// load). Empty when audio isn't ready or the base asset is missing.
    music_layers: []MusicLayer = &.{},
    /// Whether `init` succeeded in opening the audio device. If false,
    /// all methods no-op (the game runs silent, never crashes).
    audio_ready: bool = false,

    /// Open the audio device and load all sfx + the music stream from the
    /// file source. Called once after construction (settings are available).
    /// Idempotent: a second call when already ready no-ops. If the audio
    /// device can't open, `audio_ready` stays false and all methods
    /// no-op — the game runs silent, never crashes. See DESIGN → Audio.
    pub fn init(
        self: *Audio,
        settings: types.Settings,
        diagnostics_sink: ?DiagnosticsSink,
        diagnostics_context: ?*anyopaque,
    ) void {
        if (self.audio_ready) return;
        rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return;
        self.audio_ready = true;

        // Load + start the music streams FIRST (looping): the base track,
        // then the intensity layers (probed until the first missing file —
        // see `music_layers`). raylib's stb_vorbis keeps a POINTER to the
        // buffer (no copy), so each layer holds its own bytes in
        // `music_layers[i].data`, freed in `deinit`. Loading music
        // before sfx: LoadSoundFromWave converts to the device format, and
        // the music stream's setup must happen first so the sfx conversion
        // targets the right state.
        var layers: std.ArrayListUnmanaged(MusicLayer) = .empty;
        var layer_index: usize = 0;
        while (layer_index < max_music_layers) : (layer_index += 1) {
            var path_buffer: [path_buffer_size]u8 = undefined;
            const path: []const u8 = if (layer_index == 0)
                "assets/audio/music/ambient"
            else
                std.fmt.bufPrint(
                    &path_buffer,
                    "assets/audio/music/ambient_layer_{d}",
                    .{layer_index},
                ) catch @panic("failed to build music layer path");
            const audio_file = self.file_source.readAudioFile(self.allocator, path) orelse break;
            const stream = rl.loadMusicStreamFromMemory(audio_file.format, audio_file.bytes) catch {
                self.allocator.free(audio_file.bytes);
                break;
            };
            var music = stream;
            music.looping = true;
            // Base on; layers start silent (their volumes are driven by
            // the per-frame active-enemy projection in `updateMusic`).
            layers.append(self.allocator, .{
                .stream = music,
                .data = audio_file.bytes,
                .volume = if (layer_index == 0) 1.0 else 0.0,
            }) catch @panic("failed to append music layer");
            // Phase-lock check: stems must be identical-length loops or the
            // layers drift apart as they loop independently (best-effort
            // report through the caller's diagnostics sink — never let a
            // diagnostics write crash init).
            if (layer_index > 0 and layers.items[0].stream.frameCount != music.frameCount) {
                if (diagnostics_sink) |sink| {
                    var message_buffer: [160]u8 = undefined;
                    if (std.fmt.bufPrint(
                        &message_buffer,
                        "music layer {d} frame count {d} != base {d} (stems must be identical-length loops)\n",
                        .{ layer_index, music.frameCount, layers.items[0].stream.frameCount },
                    )) |message| {
                        sink(diagnostics_context, message);
                    } else |_| {
                        // Best-effort: a format overflow (absurd frame
                        // counts) is skipped, never fatal.
                    }
                }
            }
            rl.playMusicStream(music);
        }
        self.music_layers = layers.toOwnedSlice(self.allocator) catch
            @panic("failed to finalize music layers");

        // Load every sfx AFTER the music stream is set up. A missing/unreadable
        // file caches null (the game continues silent for that sound).
        for (std.meta.tags(types.SoundId)) |sound| {
            self.ensureSoundLoaded(sound);
        }

        self.applyMusicVolumes(settings);
    }

    /// Load a single sfx from the file source into the sound cache. Caches
    /// null on miss/failure (idempotent via cache presence).
    fn ensureSoundLoaded(self: *Audio, sound: types.SoundId) void {
        if (self.sound_cache.contains(sound)) return;
        // The stem is the tag name by construction — every base/one-shot
        // file is named exactly after its enum variant (extension-less;
        // `.wav`/`.ogg` via `FileSource.readAudioFile`).
        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "assets/audio/sfx/{s}",
            .{@tagName(sound)},
        ) catch @panic("failed to build sfx path");
        const loaded: ?rl.Sound = blk: {
            const audio_file = self.file_source.readAudioFile(self.allocator, path) orelse
                break :blk null;
            defer self.allocator.free(audio_file.bytes);
            const wave = rl.loadWaveFromMemory(audio_file.format, audio_file.bytes) catch break :blk null;
            defer rl.unloadWave(wave);
            const s = rl.loadSoundFromWave(wave);
            if (!rl.isSoundValid(s)) break :blk null;
            break :blk s;
        };
        self.sound_cache.put(self.allocator, sound, loaded) catch
            @panic("failed to cache sound");
    }

    /// Tear down audio: stop + unload the music streams, unload all sfx,
    /// close the audio device. Safe to call when audio was never
    /// initialized (no-op).
    pub fn deinit(self: *Audio) void {
        if (!self.audio_ready) return;
        for (self.music_layers) |*layer| {
            rl.stopMusicStream(layer.stream);
            rl.unloadMusicStream(layer.stream);
            self.allocator.free(layer.data);
        }
        // toOwnedSlice on an empty list yields a zero-length slice —
        // freeing that would be invalid (the freeMissions discipline).
        if (self.music_layers.len > 0) {
            self.allocator.free(self.music_layers);
        }
        self.music_layers = &.{};
        var sounds = self.sound_cache.valueIterator();
        while (sounds.next()) |maybe_sound| {
            if (maybe_sound.*) |sound| rl.unloadSound(sound);
        }
        self.sound_cache.deinit(self.allocator);
        var skill_layers = self.skill_layer_cache.valueIterator();
        while (skill_layers.next()) |maybe_sound| {
            if (maybe_sound.*) |sound| rl.unloadSound(sound);
        }
        self.skill_layer_cache.deinit(self.allocator);
        var action_layers = self.action_layer_cache.valueIterator();
        while (action_layers.next()) |maybe_sound| {
            if (maybe_sound.*) |sound| rl.unloadSound(sound);
        }
        self.action_layer_cache.deinit(self.allocator);
        var item_layers = self.item_layer_cache.valueIterator();
        while (item_layers.next()) |maybe_sound| {
            if (maybe_sound.*) |sound| rl.unloadSound(sound);
        }
        self.item_layer_cache.deinit(self.allocator);
        // std's HashMapUnmanaged.deinit ends with `self.* = undefined` —
        // the Debug 0xAA fill makes `metadata` a NON-NULL misaligned pointer
        // (0xAAAAAAAA), so the first `contains` after a deinit->init cycle
        // derefs it + panics with "incorrect alignment" (the import re-boot
        // crash: deinitAudio leaves the caches here, initAudio's first
        // ensureSoundLoaded -> contains trips it). A struct intended for
        // REUSE must be re-initialized to the empty state after deinit.
        self.sound_cache = .empty;
        self.skill_layer_cache = .empty;
        self.action_layer_cache = .empty;
        self.item_layer_cache = .empty;
        rl.closeAudioDevice();
        self.audio_ready = false;
    }

    /// Play the drained sound cues. Each cue plays its base layer and its
    /// specific layer (if any) simultaneously — mix balance is baked into
    /// the asset files, both layers play at the sfx volume. A missing base or
    /// layer file is SILENT — no fallbacks anywhere, silence is the
    /// "not authored yet" signal (the report tool lists every path). No-op
    /// when audio isn't ready. See DESIGN → Audio (layered cues).
    pub fn playSounds(self: *Audio, sounds: []const types.SoundCue, settings: types.Settings) void {
        if (!self.audio_ready) return;
        const master = @as(f32, @floatFromInt(settings.master_volume)) / 100.0;
        const sfx_vol = @as(f32, @floatFromInt(settings.sound_effects_volume)) / 100.0;
        const volume = sfx_vol * master;
        for (sounds) |cue| {
            if (cue.base) |base| {
                if (self.sound_cache.get(base)) |maybe_loaded| {
                    if (maybe_loaded) |loaded| {
                        rl.setSoundVolume(loaded, volume);
                        rl.playSound(loaded);
                    }
                }
            }
            if (cue.layer) |layer| switch (layer) {
                .skill => |skill_id| {
                    if (self.getSkillLayer(skill_id)) |loaded| {
                        rl.setSoundVolume(loaded, volume);
                        rl.playSound(loaded);
                    }
                },
                .action => |action| {
                    if (self.getActionLayer(action)) |loaded| {
                        rl.setSoundVolume(loaded, volume);
                        rl.playSound(loaded);
                    }
                },
                .item => |item_action| {
                    if (self.getItemLayer(item_action)) |loaded| {
                        rl.setSoundVolume(loaded, volume);
                        rl.playSound(loaded);
                    }
                },
            };
        }
    }

    /// The loaded layer sound for `skill_id`, or null when no file
    /// exists. Lazy, hit-only caching — a miss is retried on the next cue
    /// (so a dropped file works without relaunching); a hit is cached for
    /// the session (decoded audio is immutable per file path).
    fn getSkillLayer(self: *Audio, skill_id: types.SkillId) ?rl.Sound {
        if (self.skill_layer_cache.get(skill_id)) |cached| return cached;
        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "assets/audio/sfx/skills/{s}_layer",
            .{@tagName(skill_id)},
        ) catch @panic("failed to build skill layer path");
        const loaded = self.loadSoundLayerAt(path);
        if (loaded) |sound| {
            self.skill_layer_cache.put(self.allocator, skill_id, sound) catch
                @panic("failed to cache skill layer");
        }
        return loaded;
    }

    /// The loaded layer sound for `action`, or null when no file exists.
    /// Same lazy hit-only caching discipline as `getSkillLayer`.
    fn getActionLayer(self: *Audio, action: types.Action) ?rl.Sound {
        if (self.action_layer_cache.get(action)) |cached| return cached;
        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "assets/audio/sfx/buttons/{s}_layer",
            .{@tagName(action)},
        ) catch @panic("failed to build action layer path");
        const loaded = self.loadSoundLayerAt(path);
        if (loaded) |sound| {
            self.action_layer_cache.put(self.allocator, action, sound) catch
                @panic("failed to cache action layer");
        }
        return loaded;
    }

    /// The loaded layer sound for the item action `item_action`
    /// (equip / salvage / learn_skill), or null when no file exists. Same
    /// lazy hit-only caching discipline as `getSkillLayer`.
    fn getItemLayer(self: *Audio, item_action: types.ItemActionSound) ?rl.Sound {
        if (self.item_layer_cache.get(item_action)) |cached| return cached;
        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "assets/audio/sfx/items/{s}_layer",
            .{@tagName(item_action)},
        ) catch @panic("failed to build item layer path");
        const loaded = self.loadSoundLayerAt(path);
        if (loaded) |sound| {
            self.item_layer_cache.put(self.allocator, item_action, sound) catch
                @panic("failed to cache item layer");
        }
        return loaded;
    }

    /// Load a layer sound from `path_without_extension` (the FileSource
    /// audio candidate policy applies — `.wav` then `.ogg`). Returns null
    /// on any miss/decode failure; the caller decides caching.
    fn loadSoundLayerAt(self: *Audio, path_without_extension: []const u8) ?rl.Sound {
        const audio_file = self.file_source.readAudioFile(self.allocator, path_without_extension) orelse
            return null;
        defer self.allocator.free(audio_file.bytes);
        const wave = rl.loadWaveFromMemory(audio_file.format, audio_file.bytes) catch return null;
        defer rl.unloadWave(wave);
        const sound = rl.loadSoundFromWave(wave);
        if (!rl.isSoundValid(sound)) return null;
        return sound;
    }

    /// Advance every music stream each frame (raylib requires it for
    /// streaming) + drive the intensity layers: each layer's volume lerps
    /// toward its target — the base always 1.0, layer i on when
    /// `active_enemy_count >= i` — then the music/master settings scaling
    /// is applied. `active_enemy_count` is the frame's projection of ALIVE,
    /// AGGRO'D, enemy-team entities: a state projection, not an event, so
    /// it is replay/undo-safe by construction (see DESIGN → Audio —
    /// layered music). No-op when audio isn't ready.
    pub fn updateMusic(
        self: *Audio,
        active_enemy_count: u32,
        delta_microseconds: u64,
        settings: types.Settings,
    ) void {
        if (!self.audio_ready) return;
        const fade_fraction = @min(
            @as(f32, 1.0),
            @as(f32, @floatFromInt(delta_microseconds)) /
                @as(f32, @floatFromInt(music_fade_microseconds)),
        );
        for (self.music_layers, 0..) |*layer, layer_index| {
            rl.updateMusicStream(layer.stream);
            const target: f32 = if (layer_index == 0)
                1.0
            else if (active_enemy_count >= layer_index)
                musicLayerVolume(layer_index)
            else
                0.0;
            layer.volume += (target - layer.volume) * fade_fraction;
        }
        self.applyMusicVolumes(settings);
    }

    /// Apply the music/master settings scaling to every layer's current
    /// tier volume (the settings half of a layer's final volume — the
    /// tier half is `layer.volume`). Called per frame from `updateMusic`
    /// and once at init so the first stream never blares at raylib's
    /// default volume. No-op when audio isn't ready.
    fn applyMusicVolumes(self: *Audio, settings: types.Settings) void {
        if (!self.audio_ready) return;
        const master = @as(f32, @floatFromInt(settings.master_volume)) / 100.0;
        const music_vol = @as(f32, @floatFromInt(settings.music_volume)) / 100.0;
        for (self.music_layers) |*layer| {
            rl.setMusicVolume(layer.stream, layer.volume * music_vol * master);
        }
    }
};
