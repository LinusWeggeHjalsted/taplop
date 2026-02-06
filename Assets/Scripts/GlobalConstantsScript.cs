using UnityEngine;

public class GlobalConstantsScript : MonoBehaviour
{
    public static GlobalConstantsScript Instance { get; private set; }

    // save file validation constants
    public int maxSaveFileSize = 1000000; // 1MB
    public int maxPlayerNameLength = 16;
    public int maxStringLength = 64;
    public int maxDiscoveredHubs = 64;
    public int maxUnlockedSkills = 64;
    public int maxInventorySize = 24 * 4;
    public int maxClones = 64;

    // min/max ranges for player stats
    public int minRandomSeed = int.MinValue;
    public int maxRandomSeed = int.MaxValue;
    public int minTurns = 0;
    public int maxTurns = int.MaxValue;
    public int minDeaths = 0;
    public int maxDeaths = int.MaxValue;
    public int minDefeatedEnemies = 0;
    public int maxDefeatedEnemies = int.MaxValue;
    public int minSalvage = 0;
    public int maxSalvage = int.MaxValue;
    public int minInventoryPosition = 1;
    public int maxInventoryPosition = 24 * 4;

    // max values for gear stats
    public int maxWeaponDamage = 10;
    public int maxSpellDamage = 10;
    public int maxArmor = 5;
    public int maxHealthBonus = 20;
    public int maxDamageBonus = 5;
    public int maxPickupRadius = 3;
    public int maxSpeedBonus = 2;
    public int maxUtilitySkillSlots = 5;

    // min values for gear stats
    public int minWeaponDamage = 0;
    public int minSpellDamage = 0;
    public int minArmor = 0;
    public int minHealthBonus = 0;
    public int minDamageBonus = 0;
    public int minPickupRadius = 0;
    public int minSpeedBonus = 0;
    public int minUtilitySkillSlots = 0;

    // valid resource names for save file validation
    public string[] validWeaponTypes = new string[] {
        "Axe",
        "Dagger",
        "Shield",
        "Spear",
        "Sword",
        "Wand"
    };

    public string[] validSkillNames = new string[] {
        "Bash",
        "Blink",
        "Blitz",
        "Chop",
        "Cleave",
        "Daze",
        "Flash Strike",
        "Focus",
        "Howl",
        "Impale",
        "Reflect",
        "Replenish",
        "Retreating Swipe",
        "Shadow Strike",
        "Skewer",
        "Slam",
        "Slice",
        "Spark",
        "Spinblade",
        "Stab",
        "Stone Form",
        "Swap",
        "That Which Lingers",
        "Throw",
        "Toss",
        "Vampiric Strike"
    };

    public string[] validItemTypes = new string[] {
        "Weapon",
        "Amulet",
        "Coat",
        "Gloves",
        "Pants",
        "Boots",
        "Tome"
    };

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
            DontDestroyOnLoad(this.gameObject);
        }
        else
        {
            Destroy(this.gameObject);
        }
    }
}
