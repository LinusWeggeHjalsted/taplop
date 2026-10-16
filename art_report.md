# Ziglop art asset overview

Auto-generated from the engine's enums, the source tree's sprite-id
literals, and the shipped content's `sprite` references — every
sprite id the game can consume, with status. Regenerate with
`scripts/art_report.sh`.

**How to add or replace art:** drop a PNG at
`/home/strider/.ziglop/assets/<id>.png` — the persistent directory overrides the
shipped copy (asset shadowing) and is checked at every launch. Or
place it in the repo's `assets/` tree (shipped) — the game embeds
assets at BUILD time, so a repo copy needs a rebuild to show up.

**Missing = magenta.** A missing sprite draws a magenta placeholder
at its destination rect (no fallbacks), so the status column is the
complete truth about what is done and what is missing.

Included consumption sources (conservative — an id used only by a
test still reports consumed): engine enums + derivations (skills,
effects, items, weapons), every sprite-id string literal under
`src/`, every `sprite <stem>` reference in shipped data
(levels/hubs/decorations/editor defaults, mapped by section:
Entities -> entities/, Decorations -> decorations/, NPCs -> npcs/).

Hand-maintained notes (each retires when its condition lands):
- `ui/icon_undo` serves double duty as the redo button's glyph (drawn
flipped); a future `ui/icon_redo` replaces it, at which point this note
and the code alias both retire. Until then `ui/icon_redo` correctly does
not appear as consumed.
- The `npcs/` palette (dream_guide, gear_upgrader) is future stock for the
campaign editor's `npc_type` model (DESIGN → Campaigns & the Campaign
Editor → File formats) — nothing consumes the namespace until that slice
lands; today hub NPCs render through the entity path.

## MISSING — the shopping list

- `assets/entities/custom_fighter.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/entities/custom_helmet.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/entities/skeleton_armor.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/decorations/moss_1.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/decorations/moss_vine.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/decorations/ruin_1_moss.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/ui/close_button.png` — code-referenced (src/ui/element.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_playtest.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_swap.png` — code-referenced (src/ui/bottom_bar.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_undo.png` — code-referenced (src/ui/screens.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_validate.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/ui/momentum.png` — code-referenced (src/ui/bottom_bar.zig) **[MISSING (draws magenta)]**

## entities (12 consumed)

- `assets/entities/bear.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/entities/crab.png` — content-referenced (data/campaigns/main_campaign/missions/wetlands/level_3.txt) **[shipped]**
- `assets/entities/custom_fighter.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/entities/custom_helmet.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/entities/giant_crab.png` — content-referenced (data/campaigns/main_campaign/missions/wetlands/level_3.txt) **[shipped]**
- `assets/entities/player.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/entities/skeleton.png` — code-referenced (src/ui/editor_shell.zig) **[shipped]**
- `assets/entities/skeleton_1.png` — code-referenced (src/types.zig) **[shipped]**
- `assets/entities/skeleton_2.png` — content-referenced (data/campaigns/main_campaign/missions/seatown/level_3.txt) **[shipped]**
- `assets/entities/skeleton_3.png` — content-referenced (data/campaigns/main_campaign/missions/seatown/level_3.txt) **[shipped]**
- `assets/entities/skeleton_armor.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/entities/wolf.png` — code-referenced (src/ui/editor_shell.zig) **[shipped]**

## weapons (12 consumed)

- `assets/weapons/axe.png` — player body + weapon art (team 0 uses the plain art) **[shipped]**
- `assets/weapons/dagger.png` — player body + weapon art (team 0 uses the plain art) **[shipped]**
- `assets/weapons/enemy_axe.png` — enemy weapon art (the enemy_ variant) **[shipped]**
- `assets/weapons/enemy_dagger.png` — enemy weapon art (the enemy_ variant) **[shipped]**
- `assets/weapons/enemy_shield.png` — enemy weapon art (the enemy_ variant) **[shipped]**
- `assets/weapons/enemy_spear.png` — enemy weapon art (the enemy_ variant) **[shipped]**
- `assets/weapons/enemy_staff.png` — enemy weapon art (the enemy_ variant) **[shipped]**
- `assets/weapons/enemy_sword.png` — enemy weapon art (the enemy_ variant) **[shipped]**
- `assets/weapons/shield.png` — player body + weapon art (team 0 uses the plain art) **[shipped]**
- `assets/weapons/spear.png` — player body + weapon art (team 0 uses the plain art) **[shipped]**
- `assets/weapons/staff.png` — player body + weapon art (team 0 uses the plain art) **[shipped]**
- `assets/weapons/sword.png` — player body + weapon art (team 0 uses the plain art) **[shipped]**

## items (12 consumed)

- `assets/items/amulet.png` — item icon **[shipped]**
- `assets/items/axe.png` — weapon item icon **[shipped]**
- `assets/items/boots.png` — item icon **[shipped]**
- `assets/items/coat.png` — item icon **[shipped]**
- `assets/items/dagger.png` — weapon item icon **[shipped]**
- `assets/items/gloves.png` — item icon **[shipped]**
- `assets/items/pants.png` — item icon **[shipped]**
- `assets/items/shield.png` — weapon item icon **[shipped]**
- `assets/items/skill_tome.png` — item icon **[shipped]**
- `assets/items/spear.png` — weapon item icon **[shipped]**
- `assets/items/staff.png` — weapon item icon **[shipped]**
- `assets/items/sword.png` — weapon item icon **[shipped]**

## skills (44 consumed)

- `assets/skills/absorb.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/accelerate.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/adrenaline_surge.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/bash.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/blink.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/blitz.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/bull_form.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/burst.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/chain_lightning.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/charged_bolt.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/chop.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/cleave.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/drain.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/flash_strike.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/focus.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/head_shot.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/heal.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/howl.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/impale.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/meditate.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/meteor.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/powerful_shot.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/promise_of_death.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/reflect.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/replenish.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/retreating_swipe.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/shockwave.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/shoot.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/skewer.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/slam.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/slice.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/spark.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/spinblade.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/stab.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/stone_form.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/swap.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/that_which_explodes.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/that_which_lingers.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/that_which_reaches.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/that_which_rushes.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/throw.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/toss.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/vampiric_strike.png` — skill icon (palette, buttons, tooltips) **[shipped]**
- `assets/skills/worldfire.png` — skill icon (palette, buttons, tooltips) **[shipped]**

## effects (2 consumed)

- `assets/effects/reflect.png` — world overlay for the effect **[shipped]**
- `assets/effects/stun.png` — code-referenced (src/view.zig) **[shipped]**

## decorations (51 consumed)

- `assets/decorations/moss_1.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/decorations/moss_vine.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/decorations/ruin_1.png` — code-referenced (src/ui/editor_shell.zig) **[shipped]**
- `assets/decorations/ruin_10.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/ruin_11.png` — content-referenced (data/campaigns/main_campaign/missions/beginnings/level_1.txt) **[shipped]**
- `assets/decorations/ruin_1_moss.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/decorations/ruin_2.png` — content-referenced (data/campaigns/main_campaign/missions/beginnings/level_2.txt) **[shipped]**
- `assets/decorations/ruin_3.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/ruin_4.png` — content-referenced (data/campaigns/main_campaign/missions/forest/level_2.txt) **[shipped]**
- `assets/decorations/ruin_5.png` — content-referenced (data/campaigns/main_campaign/missions/wetlands/level_3.txt) **[shipped]**
- `assets/decorations/ruin_6.png` — content-referenced (data/campaigns/main_campaign/missions/wetlands/level_3.txt) **[shipped]**
- `assets/decorations/ruin_7.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/ruin_8.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/ruin_9.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/statue_1.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/statue_2.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/statue_3.png` — content-referenced (data/campaigns/main_campaign/missions/beginnings/level_2.txt) **[shipped]**
- `assets/decorations/statue_4.png` — content-referenced (data/campaigns/main_campaign/missions/beginnings/level_1.txt) **[shipped]**
- `assets/decorations/statue_5.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/stone_1.png` — content-referenced (data/campaigns/main_campaign/missions/wetlands/level_3.txt) **[shipped]**
- `assets/decorations/stone_2.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/decorations/stone_3.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/stone_4.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/stone_5.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/stone_6.png` — content-referenced (data/campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt) **[shipped]**
- `assets/decorations/tent.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_1.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/decorations/tree_1_canopy.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/decorations/tree_1_grass.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/decorations/tree_1_grass_back.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/decorations/tree_1_moss.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/decorations/tree_2.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_2_canopy.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_2_grass.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_2_grass_back.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_2_moss.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_3.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_3_canopy.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_3_grass.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_3_grass_back.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_3_moss.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_4.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_4_canopy.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_4_grass.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_4_grass_back.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_4_moss.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_5.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_5_canopy.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_5_grass.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_5_grass_back.png` — content-referenced (data/decorations.txt) **[shipped]**
- `assets/decorations/tree_5_moss.png` — content-referenced (data/decorations.txt) **[shipped]**

## ui (26 consumed)

- `assets/ui/button_background.png` — code-referenced (src/ui/emit.zig) **[shipped]**
- `assets/ui/close_button.png` — code-referenced (src/ui/element.zig) **[MISSING (draws magenta)]**
- `assets/ui/health_globe.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**
- `assets/ui/health_globe_border.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**
- `assets/ui/icon_gear.png` — code-referenced (src/types.zig) **[shipped]**
- `assets/ui/icon_inventory.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**
- `assets/ui/icon_options.png` — code-referenced (src/ui/screens.zig) **[shipped]**
- `assets/ui/icon_playtest.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_skills.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**
- `assets/ui/icon_skip.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**
- `assets/ui/icon_swap.png` — code-referenced (src/ui/bottom_bar.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_undo.png` — code-referenced (src/ui/screens.zig) **[MISSING (draws magenta)]**
- `assets/ui/icon_validate.png` — code-referenced (src/ui/editor_shell.zig) **[MISSING (draws magenta)]**
- `assets/ui/item_slot.png` — code-referenced (src/ui/panels.zig) **[shipped]**
- `assets/ui/material_cloth.png` — code-referenced (src/ui/emit.zig) **[shipped]**
- `assets/ui/material_knowledge.png` — code-referenced (src/ui/emit.zig) **[shipped]**
- `assets/ui/material_leather.png` — code-referenced (src/ui/emit.zig) **[shipped]**
- `assets/ui/material_metal.png` — code-referenced (src/ui/emit.zig) **[shipped]**
- `assets/ui/material_wood.png` — code-referenced (src/ui/emit.zig) **[shipped]**
- `assets/ui/momentum.png` — code-referenced (src/ui/bottom_bar.zig) **[MISSING (draws magenta)]**
- `assets/ui/panel.png` — code-referenced (src/handler_tests_editor.zig) **[shipped]**
- `assets/ui/salvage_tool.png` — code-referenced (src/ui/panels.zig) **[shipped]**
- `assets/ui/skill_button.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/ui/skill_slot_empty.png` — code-referenced (src/ui/editor_pickers.zig) **[shipped]**
- `assets/ui/turn_attack.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**
- `assets/ui/turn_move.png` — code-referenced (src/ui/bottom_bar.zig) **[shipped]**

## world (8 consumed)

- `assets/world/aggro.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/world/entity_health_bar_background.png` — code-referenced (src/raylib/draw.zig) **[shipped]**
- `assets/world/entity_health_bar_outline.png` — code-referenced (src/raylib/draw.zig) **[shipped]**
- `assets/world/flag.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/world/flag_pole.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/world/ground_items.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/world/hit_flash.png` — code-referenced (src/view.zig) **[shipped]**
- `assets/world/tile.png` — code-referenced (src/types.zig) **[shipped]**

## Shipped but unconsumed

Palette stock (the editor pickers offer every shipped sprite in the
entity/decoration namespaces, so unconsumed is not necessarily dead)
or art nothing references — the artist's call.

**entities:**

- `assets/entities/raider.png` — shipped, nothing consumes it
- `assets/entities/snake.png` — shipped, nothing consumes it
- `assets/entities/frog.png` — shipped, nothing consumes it
- `assets/entities/mushroom.png` — shipped, nothing consumes it
- `assets/entities/ghoul.png` — shipped, nothing consumes it
- `assets/entities/specter.png` — shipped, nothing consumes it

**npcs:**

- `assets/npcs/gear_upgrader.png` — shipped, nothing consumes it
- `assets/npcs/dream_guide.png` — shipped, nothing consumes it
