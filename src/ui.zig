const types = @import("types.zig");

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;

// ============================================================
// UI state — lives on GameState, tracks what's open
// ============================================================

pub const MiddlePanelId = enum {
    inventory,
    gear,
    skills,
    enemy_inspect,
};

pub const FullScreenOverlayId = enum {
    world_map,
    full_combat_log,
};

pub const max_middle_panels = 4;
pub const max_full_screen_overlays = 2;

pub const UiState = struct {
    /// Middle section panels, ordered by open time (first opened = leftmost).
    open_middle_panels: [max_middle_panels]?MiddlePanelId = .{null} ** max_middle_panels,

    /// Full-screen overlays that can stack (world map, full combat log).
    open_full_screen_overlays: [max_full_screen_overlays]?FullScreenOverlayId = .{null} ** max_full_screen_overlays,

    /// Options menu is separate — always on top, locks input.
    options_menu_open: bool = false,

    /// Which entity is being inspected (for enemy_inspect panel).
    inspected_entity_index: ?u32 = null,

    /// Middle section horizontal scroll offset (for when panels exceed width).
    middle_section_scroll_offset: i32 = 0,

    /// Combat log scroll offset (for full combat log view).
    combat_log_scroll_offset: i32 = 0,

    /// Active tooltip, if any.
    active_tooltip: ?TooltipState = null,

    pub fn toggleMiddlePanel(self: *UiState, panel_id: MiddlePanelId) void {
        // If already open, close it
        for (&self.open_middle_panels) |*slot| {
            if (slot.*) |open| {
                if (open == panel_id) {
                    slot.* = null;
                    return;
                }
            }
        }
        // Not open — find first empty slot
        for (&self.open_middle_panels) |*slot| {
            if (slot.* == null) {
                slot.* = panel_id;
                return;
            }
        }
    }

    pub fn toggleFullScreenOverlay(self: *UiState, overlay_id: FullScreenOverlayId) void {
        for (&self.open_full_screen_overlays) |*slot| {
            if (slot.*) |open| {
                if (open == overlay_id) {
                    slot.* = null;
                    return;
                }
            }
        }
        for (&self.open_full_screen_overlays) |*slot| {
            if (slot.* == null) {
                slot.* = overlay_id;
                return;
            }
        }
    }
};

pub const TooltipState = struct {
    /// Screen position of the element that spawned the tooltip.
    source_position: ScreenPosition,
    source_width: u32,
    source_height: u32,
    header: []const u8,
    body: []const u8,
};

// ============================================================
// Layout constants — fixed sizes in reference resolution
// ============================================================

pub const top_bar_height: u32 = 100;
pub const bottom_bar_height: u32 = 160;
pub const slot_size: u32 = 120;
pub const slot_padding: u32 = 8;
pub const panel_border: u32 = 16; // 9-slice border thickness
pub const gear_panel_width: u32 = 200;
pub const inventory_panel_width: u32 = 1100;
pub const skills_panel_width: u32 = 800;
pub const enemy_inspect_panel_width: u32 = 600;

// ============================================================
// UI elements — building blocks for the view function
// ============================================================

/// A 9-slice panel background. The sprite has fixed-size corners and
/// edges that don't stretch, with a center region that fills.
pub const NineSlicePanel = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: u32,
    height: u32,
    border: u32,
    color: Color,
};

/// A clickable slot (inventory cell, gear slot, skill bar slot).
pub const Slot = struct {
    screen_position: ScreenPosition,
    size: u32,
    /// The icon inside the slot, if any.
    icon_sprite_id: ?[]const u8 = null,
    icon_color: Color = .{ .r = 255, .g = 255, .b = 255 },
    /// Cooldown overlay (0 = no cooldown, fraction of slot filled).
    cooldown_fraction: f32 = 0,
    /// Tooltip shown on hover.
    tooltip_header: ?[]const u8 = null,
    tooltip_body: ?[]const u8 = null,
};

/// A clickable button with a sprite. Clicking triggers the same
/// action as the corresponding keybind.
pub const Button = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: u32,
    height: u32,
    color: Color,
    action: Action,
    tooltip_header: ?[]const u8 = null,
    tooltip_body: ?[]const u8 = null,
};

/// A text label.
pub const TextLabel = struct {
    text: []const u8,
    screen_position: ScreenPosition,
    color: Color,
    font_size: u32,
};

/// A horizontal bar (health, cooldown).
pub const Bar = struct {
    screen_position: ScreenPosition,
    width: u32,
    height: u32,
    current_value: u32,
    max_value: u32,
    fill_color: Color,
    background_color: Color,
};

/// A sprite image (icon, decoration, etc.).
pub const Image = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: u32,
    height: u32,
    color: Color,
};

/// Any UI element that can appear in a panel.
pub const UiElement = union(enum) {
    nine_slice_panel: NineSlicePanel,
    slot: Slot,
    button: Button,
    text_label: TextLabel,
    bar: Bar,
    image: Image,
};

// ============================================================
// Tooltip corner selection
// ============================================================

pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

/// Pick which corner of the tooltip to anchor to which corner of the
/// source element, so the tooltip stays on screen.
/// Returns the corner of the source element and the corner of the tooltip
/// that should meet.
pub fn selectTooltipCorners(
    source_position: ScreenPosition,
    source_width: u32,
    source_height: u32,
    tooltip_width: u32,
    tooltip_height: u32,
) struct { source_corner: Corner, tooltip_corner: Corner } {
    const source_center_x = source_position.x + @as(i32, @intCast(source_width / 2));
    const source_center_y = source_position.y + @as(i32, @intCast(source_height / 2));
    const screen_center_x: i32 = @intCast(types.reference_width / 2);
    const screen_center_y: i32 = @intCast(types.reference_height / 2);

    // Place tooltip away from the nearest screen edge.
    // If source is in the left half, tooltip goes to the right (and vice versa).
    // If source is in the top half, tooltip goes below (and vice versa).
    const tooltip_goes_right = source_center_x < screen_center_x;
    const tooltip_goes_down = source_center_y < screen_center_y;

    // The source corner is the one closest to where the tooltip will be.
    // The tooltip corner is the opposite — they meet at those corners.
    if (tooltip_goes_right and tooltip_goes_down) {
        // Tooltip appears to the bottom-right of the source.
        // Source's bottom-right corner meets tooltip's top-left corner.
        return .{ .source_corner = .bottom_right, .tooltip_corner = .top_left };
    } else if (!tooltip_goes_right and tooltip_goes_down) {
        return .{ .source_corner = .bottom_left, .tooltip_corner = .top_right };
    } else if (tooltip_goes_right and !tooltip_goes_down) {
        return .{ .source_corner = .top_right, .tooltip_corner = .bottom_left };
    } else {
        return .{ .source_corner = .top_left, .tooltip_corner = .bottom_right };
    }

    // Suppress unused parameter warnings — these will be used when we
    // refine the logic to check actual overflow against screen edges.
    _ = tooltip_width;
    _ = tooltip_height;
}

// ============================================================
// Panel content builders — called by the view function
// ============================================================

// These will be implemented to build UiElement slices for each
// panel type. The view function calls the relevant builder based
// on game state and assembles the full UI layout.

// buildTopBar(game_state) → []UiElement
// buildBottomBar(game_state) → []UiElement
// buildGearPanel(game_state) → []UiElement
// buildInventoryPanel(game_state) → []UiElement
// buildSkillsPanel(game_state) → []UiElement
// buildEnemyInspectPanel(game_state, entity_index) → []UiElement
// buildWorldMap(game_state) → []UiElement
// buildFullCombatLog(game_state) → []UiElement
// buildOptionsMenu(game_state) → []UiElement
// buildMainMenu() → []UiElement
// buildMissionComplete(game_state) → []UiElement
// buildMissionFail(game_state) → []UiElement
// buildTooltip(tooltip_state) → []UiElement
