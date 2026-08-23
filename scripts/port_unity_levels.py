#!/usr/bin/env python3
"""Convert Unity level/hub files (~/Development/taplop) into ziglop format.

One-off port script. Run from the ziglop project root. Writes into
data/campaigns/main_campaign/. Does NOT touch first_mission/starting_village
(dev/sample content referenced by tests + editor entry).
"""
import os, re, sys, struct

UNITY = os.path.expanduser("~/Development/taplop/Assets/Resources")
ZIG = "data/campaigns/main_campaign"

# ── name conversions ────────────────────────────────────────────────────────

def to_snake(name):
    """CamelCase / digit-bearing → snake_case stem. GiantCrab->giant_crab, Skeleton1->skeleton_1, Ruin11->ruin_11."""
    s = re.sub(r'(?<=[a-z])(?=[A-Z])', '_', name)   # lower->Upper boundary
    s = re.sub(r'(?<=[A-Za-z])(?=\d)', '_', s)       # letter->digit boundary
    return s.lower()

WEAPON_MAP = {"Sword":"sword","Shield":"shield","Spear":"spear","Dagger":"dagger","Axe":"axe","Wand":"staff"}
SKILL_MAP = {
    "Blink":"blink","Howl":"howl","Stone Form":"stone_form","Swap":"swap",
    "Focus":"focus","That Which Lingers":"that_which_lingers","Replenish":"replenish",
}
MISSION_FOLDER = {"Beginnings":"beginnings","Forest":"forest","Wetlands":"wetlands","Seatown":"seatown"}

# footprint per decoration sprite (single-tile anchor, computed from Unity pivots)
FOOTPRINT = {
    "tree_1": "1 2",
    "ruin_1": "0 1", "ruin_2": "0 1", "ruin_3": "0 2",
    "ruin_4": "0 0", "ruin_5": "0 0", "ruin_6": "0 0",
    "ruin_7": "0 0", "ruin_8": "0 0", "ruin_9": "0 0",
    "ruin_10": "1 1", "ruin_11": "1 1",
    "statue_1": "0 1", "statue_2": "0 1", "statue_3": "0 1", "statue_4": "0 1", "statue_5": "0 2",
    "stone_1": "0 0", "stone_2": "0 0", "stone_3": "0 0", "stone_4": "0 0", "stone_5": "0 0", "stone_6": "0 1",
}

# ── Unity file parser ───────────────────────────────────────────────────────

def parse_unity_file(text):
    """Returns ordered list of (header, [lines]). Section header = a line that
    is a known section name; everything else is body lines (preserving blanks)."""
    sections = []
    cur_header = None
    cur_lines = []
    for line in text.split("\n"):
        stripped = line.strip()
        # A line with no spaces and non-empty is a section header if it matches
        # the known set; otherwise treat as body. Unity section headers we see:
        # Metadata, Layout, Enemy Info, Decoration Info, Item Info, Exit Info,
        # Info, Discovered Hubs, Unlocked Skills, Main Hand Weapon, ...
        KNOWN = {"Metadata","Layout","Enemy Info","Decoration Info","Item Info","Exit Info"}
        if stripped in KNOWN and " " not in stripped.rstrip():
            # "Enemy Info" has a space — handle multi-word headers
            pass
        if stripped in KNOWN:
            if cur_header is not None:
                sections.append((cur_header, cur_lines))
            cur_header = stripped
            cur_lines = []
        else:
            cur_lines.append(line)
    if cur_header is not None:
        sections.append((cur_header, cur_lines))
    return sections

def group_entries(lines, first_line_is_code=True):
    """Split body lines into entries. Each entry starts with a single-char
    code line (for Enemy/Decoration/Item/Exit Info); blank lines separate.
    Returns list of (code, [(key, value), ...]) or for Layout just the lines."""
    entries = []
    cur_code = None
    cur_pairs = []
    for line in lines:
        s = line.rstrip("\n")
        stripped = s.strip()
        if stripped == "":
            if cur_code is not None:
                entries.append((cur_code, cur_pairs))
                cur_code = None
                cur_pairs = []
            continue
        if cur_code is None and len(stripped) == 1:
            cur_code = stripped
            cur_pairs = []
            continue
        # key value
        parts = stripped.split(" ", 1)
        key, value = parts[0], parts[1] if len(parts) > 1 else ""
        cur_pairs.append((key, value))
    if cur_code is not None:
        entries.append((cur_code, cur_pairs))
    return entries

# ── converters ──────────────────────────────────────────────────────────────

ENEMY_FIELD_MAP = [
    ("name", "name"),
    ("sprite", "sprite"),  # converted separately
    ("maxHealth", "max_health"),
    ("armor", "defense"),
    ("speed", "speed"),
    ("aggroRange", "aggro_range"),
    ("mainHandName", "main_hand_weapon_name"),
    ("mainHandDamage", "main_hand_weapon_damage"),
    ("offHandName", "off_hand_weapon_name"),
    ("offHandDamage", "off_hand_weapon_damage"),
    ("coatName", "coat_name"),
    ("coatHealth", "coat_health_bonus"),
    ("coatArmor", "coat_defense_bonus"),
    ("glovesName", "gloves_name"),
    ("glovesHealth", "gloves_health_bonus"),
    ("glovesDamage", "gloves_damage_bonus"),
    ("pantsName", "pants_name"),
    ("pantsHealth", "pants_health_bonus"),
    ("pantsPickupRadius", "pants_pickup_radius_bonus"),
    ("bootsName", "boots_name"),
    ("bootsHealth", "boots_health_bonus"),
    ("bootsSpeed", "boots_speed_bonus"),
]

def convert_enemy(code, pairs):
    out = [f"character_code {code}"]
    uses = None
    sprite = None
    main_type = None
    off_type = None
    utilities = []
    for k, v in pairs:
        if k == "usesWeapons":
            uses = v
        elif k == "sprite":
            sprite = to_snake(v)
        elif k == "mainHandWeapon":
            main_type = WEAPON_MAP.get(v, v.lower())
        elif k == "offHandWeapon":
            off_type = WEAPON_MAP.get(v, v.lower())
        elif k == "utilitySkill":
            utilities.append(SKILL_MAP.get(v, to_snake(v)))
        else:
            mapped = dict(ENEMY_FIELD_MAP).get(k)
            if mapped:
                out.append(f"{mapped} {v}")
    if sprite:
        out.insert(1, f"sprite {sprite}")
    out.append(f"displays_weapons {'false' if uses == '0' else 'true'}")
    if main_type:
        out.append(f"main_hand_weapon_type {main_type}")
    if off_type:
        out.append(f"off_hand_weapon_type {off_type}")
    for i, skill in enumerate(utilities):
        out.append(f"slot_{4+i} {skill}")
    return "\n".join(out)

def convert_decoration(code, pairs):
    out = [f"character_code {code}"]
    for k, v in pairs:
        if k == "sprite":
            stem = to_snake(v)
            out.append(f"sprite {stem}")
            out.append(f"footprint {FOOTPRINT.get(stem, '0 0')}")
        elif k == "colorCode":
            out.append(f"color_index {v}")
    return "\n".join(out)

def convert_item(code, pairs):
    d = dict(pairs)
    name = d.get("name", "")
    typ = d.get("type", "")
    out = [f"character_code {code}"]
    if typ == "Weapon":
        out.append("item_type weapon")
        out.append(f"item_name {name}")
        out.append(f"weapon_type {WEAPON_MAP.get(d.get('weaponType','Sword'),'sword')}")
        out.append(f"damage {d.get('damage','0')}")
    elif typ == "Boots":
        out.append("item_type boots")
        out.append(f"item_name {name}")
        out.append(f"health {d.get('health','0')}")
        out.append(f"speed {d.get('speed','0')}")
    return "\n".join(out)

def convert_level(unity_path, zig_path, level_name):
    text = open(unity_path).read()
    sections = parse_unity_file(text)
    parts = []
    parts.append("Metadata")
    parts.append("file_format_version 1")
    parts.append(f"name {level_name}")
    parts.append("")
    for header, lines in sections:
        if header == "Layout":
            parts.append("Layout")
            parts.extend(lines)
            parts.append("")
        elif header == "Enemy Info":
            parts.append("Enemies")
            parts.append("")
            for code, pairs in group_entries(lines):
                parts.append(convert_enemy(code, pairs))
                parts.append("")
        elif header == "Decoration Info":
            parts.append("Decorations")
            parts.append("")
            for code, pairs in group_entries(lines):
                parts.append(convert_decoration(code, pairs))
                parts.append("")
        elif header == "Item Info":
            parts.append("Items")
            parts.append("")
            for code, pairs in group_entries(lines):
                parts.append(convert_item(code, pairs))
                parts.append("")
    # trim trailing blanks, ensure single trailing newline
    while parts and parts[-1] == "":
        parts.pop()
    os.makedirs(os.path.dirname(zig_path), exist_ok=True)
    open(zig_path, "w").write("\n".join(parts) + "\n")
    print(f"wrote {zig_path}")

def convert_hub(unity_path, zig_path):
    text = open(unity_path).read()
    sections = parse_unity_file(text)
    parts = []
    parts.append("Metadata")
    parts.append("file_format_version 1")
    parts.append("name Camp at the Crossroads")
    parts.append("")
    for header, lines in sections:
        if header == "Layout":
            parts.append("Layout")
            parts.extend(lines)
            parts.append("")
        elif header == "Decoration Info":
            parts.append("Decorations")
            parts.append("")
            for code, pairs in group_entries(lines):
                parts.append(convert_decoration(code, pairs))
                parts.append("")
        elif header == "Exit Info":
            parts.append("Exits")
            parts.append("")
            for code, pairs in group_entries(lines):
                mission_name = None
                for k, v in pairs:
                    if k == "missionName":
                        mission_name = v
                mid = MISSION_FOLDER.get(mission_name, to_snake(mission_name or ""))
                parts.append(f"character_code {code}")
                parts.append(f"mission_id {mid}")
                parts.append("")
    # NPCs section (empty)
    parts.append("NPCs")
    parts.append("")
    while parts and parts[-1] == "":
        parts.pop()
    os.makedirs(os.path.dirname(zig_path), exist_ok=True)
    open(zig_path, "w").write("\n".join(parts) + "\n")
    print(f"wrote {zig_path}")

# ── player.txt (shared starter loadout, from Unity New Game.txt) ───────────

PLAYER_TXT = """Metadata
file_format_version 1

PlayerLoadout
name Player
sprite player
max_health 20
defense 0
speed 1
aggro_range 3
main_hand_weapon_name Starter Sword
main_hand_weapon_type sword
main_hand_weapon_damage 3
off_hand_weapon_name Starter Shield
off_hand_weapon_type shield
off_hand_weapon_damage 3
amulet_name Starter Amulet
amulet_spell_damage 3
coat_name Starter Coat
coat_defense_bonus 0
coat_health_bonus 1
gloves_name Starter Gloves
gloves_damage_bonus 0
gloves_health_bonus 1
pants_name Starter Pants
pants_pickup_radius_bonus 0
pants_health_bonus 1
boots_name Starter Boots
boots_speed_bonus 0
boots_health_bonus 1
slot_4 replenish
"""

# ── mission.txt per mission ────────────────────────────────────────────────

MISSIONS = [
    ("beginnings", "Beginnings", 3),
    ("forest", "Forest", 4),
    ("wetlands", "Wetlands", 3),
    ("seatown", "Seatown", 3),
]

LEVEL_FILE_ORDER = {
    "Beginnings": ["Beginnings 0", "Beginnings 1", "Beginnings 2"],
    "Forest": ["Forest 0", "Forest 1", "Forest 2", "Forest 3"],
    "Wetlands": ["Wetlands 0", "Wetlands 1", "Wetlands 2"],
    "Seatown": ["Seatown 0", "Seatown 1", "Seatown 2"],
}

def write_mission(folder, display, count):
    mpath = f"{ZIG}/missions/{folder}"
    os.makedirs(mpath, exist_ok=True)
    open(f"{mpath}/mission.txt", "w").write(
        "Metadata\nfile_format_version 1\n"
        f"name {display}\n"
        "start_hub camp_at_the_crossroads\n"
        "end_hub camp_at_the_crossroads\n"
        f"level_count {count}\n"
    )
    open(f"{mpath}/player.txt", "w").write(PLAYER_TXT)
    print(f"wrote {mpath}/mission.txt + player.txt")

def main():
    # Hub
    convert_hub(f"{UNITY}/Hubs/Camp at the Crossroads.txt",
                f"{ZIG}/hubs/camp_at_the_crossroads/hub.txt")
    # Missions + levels
    for folder, display, count in MISSIONS:
        write_mission(folder, display, count)
        for i, lvl in enumerate(LEVEL_FILE_ORDER[display]):
            convert_level(f"{UNITY}/Levels/{lvl}.txt",
                          f"{ZIG}/missions/{folder}/level_{i+1}.txt",
                          lvl)
    # Update campaign start_hub
    open(f"{ZIG}/campaign.txt", "w").write(
        "Metadata\nfile_format_version 1\nname Main Campaign\nstart_hub camp_at_the_crossroads\n"
    )
    print(f"updated {ZIG}/campaign.txt -> start_hub camp_at_the_crossroads")

if __name__ == "__main__":
    main()
