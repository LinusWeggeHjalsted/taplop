using UnityEngine;
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public class PlayerDataScript : MonoBehaviour
{
    public static PlayerDataScript Instance { get; private set; }

#if UNITY_WEBGL && !UNITY_EDITOR
    [DllImport("__Internal")]
    private static extern void DownloadFile(string filename, string content);

    [DllImport("__Internal")]
    private static extern void UploadFile(string gameObjectName, string callbackMethodName);
#endif

    public class Salvage
    {
        public int wood;
        public int metal;
        public int leather;
        public int cloth;
        public int knowledge;

        public static Salvage operator +(Salvage salvage1, Salvage salvage2)
        {
            Salvage combinedSalvage = new Salvage();
            combinedSalvage.wood = salvage1.wood + salvage2.wood;
            combinedSalvage.metal = salvage1.metal + salvage2.metal;
            combinedSalvage.leather = salvage1.leather + salvage2.leather;
            combinedSalvage.cloth = salvage1.cloth + salvage2.cloth;
            combinedSalvage.knowledge = salvage1.knowledge + salvage2.knowledge;
            return combinedSalvage;
        }
    }

    public abstract class InventoryItemData
    {
        public string itemName;
        public int inventoryPosition;
    }

    public class WeaponData : InventoryItemData
    {
        public string weaponType;
        public int damage;
    }

    public class AmuletData : InventoryItemData
    {
        public int spellDamage;
    }

    public class CoatData : InventoryItemData
    {
        public int armor;
        public int health;
    }

    public class GlovesData : InventoryItemData
    {
        public int armor;
        public int damage;
    }

    public class PantsData : InventoryItemData
    {
        public int armor;
        public int pickupRadius;
    }

    public class BootsData : InventoryItemData
    {
        public int armor;
        public int speed;
    }

    public class TomeData : InventoryItemData
    {
        public string skillName;
    }

    public class CloneData
    {
        public Salvage totalSalvage;
        public int turnsToComplete;
    }

    public bool finishedBuilding = false;
    public bool skipAttackStep = true;

    public string playerName;
    
    // info
    public int randomSeed;
    public string lastHub;
    public int turns;
    public int deaths;
    public int defeatedEnemies;
    public Salvage collectedSalvage = new Salvage();
    public int utilitySkillSlots;
    public List<string> discoveredHubs = new List<string>();
    public List<string> unlockedSkills = new List<string>();
    // gear
    public WeaponData mainHandWeapon;
    public WeaponData offHandWeapon;
    public AmuletData amulet;
    public CoatData coat;
    public GlovesData gloves;
    public PantsData pants;
    public BootsData boots;

    // inventory
    public List<InventoryItemData> inventory = new List<InventoryItemData>();

    // utility skill names
    public string[] utilitySkills = new string[5];

    // clone data
    public Dictionary<string, CloneData> allCloneData = new Dictionary<string, CloneData>();

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

    void Start()
    {
    }

    // validation helper methods
    private bool ValidateSaveFileBasics(string fileText)
    {
        GlobalConstantsScript constants = GlobalConstantsScript.Instance;

        // file size limit
        if (fileText.Length > constants.maxSaveFileSize)
        {
            Debug.LogError("Save file too large: " + fileText.Length + " bytes (max: " + constants.maxSaveFileSize + ")");
            return false;
        }

        // validate all required sections exist
        string[] requiredSections = new string[] {
            "Info",
            "Discovered Hubs",
            "Unlocked Skills",
            "Main Hand Weapon",
            "Off Hand Weapon",
            "Amulet",
            "Coat",
            "Gloves",
            "Pants",
            "Boots",
            "Inventory",
            "Utility Skills",
            "Clone Data"
        };

        foreach (string section in requiredSections)
        {
            if (!fileText.Contains(section + "\n"))
            {
                Debug.LogError("Missing required section: " + section);
                return false;
            }
        }

        return true;
    }

    private bool ValidateIntInRange(int value, int min, int max, string fieldName)
    {
        if (value < min || value > max)
        {
            Debug.LogError(fieldName + " out of valid range (" + min + "-" + max + "): " + value);
            return false;
        }
        return true;
    }

    private bool ValidateString(string value, int maxLength, string fieldName)
    {
        if (string.IsNullOrEmpty(value))
        {
            return true; // allow empty for optional fields
        }

        if (value.Length > maxLength)
        {
            Debug.LogError(fieldName + " exceeds max length of " + maxLength + ": " + value.Length);
            return false;
        }

        // check for invalid characters
        if (value.Contains("\0") || value.Contains("\r"))
        {
            Debug.LogError(fieldName + " contains invalid characters");
            return false;
        }

        return true;
    }

    private bool ValidateResourceName(string resourceName, string[] whitelist, string fieldName)
    {
        if (string.IsNullOrEmpty(resourceName))
        {
            return true; // allow empty for optional fields
        }

        if (System.Array.IndexOf(whitelist, resourceName) < 0)
        {
            Debug.LogError(fieldName + " contains invalid resource name: " + resourceName);
            return false;
        }

        return true;
    }

    public void LoadPlayerData(string savePath)
    {
        string fileText = null;
        // try loading from persistent data path first (for saves like Autosave)
        string persistentPath = Application.persistentDataPath + "/" + savePath + ".txt";
        if (File.Exists(persistentPath))
        {
            try
            {
                fileText = File.ReadAllText(persistentPath);
            }
            catch (Exception e)
            {
                Debug.LogError("Failed to load from persistent path: " + e.Message);
            }
        }
        // fall back to resources folder if not found in persistent path
        if (fileText == null)
        {
            TextAsset playerSaveFile = Resources.Load<TextAsset>(savePath);
            if (playerSaveFile == null)
            {
                Debug.LogError("No save file found at path " + savePath);
                return;
            }
            fileText = playerSaveFile.text;
        }
        if (fileText != null)
        {
            LoadPlayerDataFromText(fileText);
        }
    }

    public void LoadPlayerDataFromText(string fileText)
    {
        if (fileText != null)
        {
            // validate basic save file structure
            if (!ValidateSaveFileBasics(fileText))
            {
                Debug.LogError("Save file failed basic validation");
                return;
            }

            string[] fileLines = fileText.Split('\n');
            string[] sectionHeaders = new string[] {
                "Info",
                "Discovered Hubs",
                "Unlocked Skills", 
                "Main Hand Weapon",
                "Off Hand Weapon",
                "Amulet",
                "Coat",
                "Gloves",
                "Pants",
                "Boots",
                "Inventory",
                "Utility Skills",
                "Clone Data"
            };
            int sectionCount = sectionHeaders.Length;
            int[] sectionIndices = new int[sectionCount];
            for (int i = 0; i < sectionCount; i++)
            {
                int sectionIndex = Array.IndexOf(fileLines, sectionHeaders[i]) + 1;
                sectionIndices[i] = sectionIndex;
            }
            // to-do: verify that sections are in correct order
            int[] sectionLengths = new int[sectionCount];
            for (int i = 0; i < sectionCount; i++)
            {
                if (i + 1 == sectionCount)
                {
                    int sectionLength = fileLines.Length - sectionIndices[i] - 2;
                    sectionLengths[i] = sectionLength;
                }
                else
                {
                    int sectionLength = sectionIndices[i + 1] - sectionIndices[i] - 2;
                    sectionLengths[i] = sectionLength;
                }

                // Check for invalid section lengths
                if (sectionLengths[i] < 0)
                {
                    Debug.LogError("Invalid section length for section " + sectionHeaders[i] + ": " + sectionLengths[i] +
                                   ". Section index: " + sectionIndices[i] + ", File may be corrupted or in old format.");
                    return;
                }
            }
            string[][] sectionBlocks = new string[sectionCount][];
            for (int i = 0; i < sectionCount; i++)
            {
                string[] sectionBlock = new string[sectionLengths[i]];
                Array.Copy(fileLines, sectionIndices[i], sectionBlock, 0, sectionLengths[i]);
                sectionBlocks[i] = sectionBlock;
            }
            
            // parse info
            GlobalConstantsScript constants = GlobalConstantsScript.Instance;
            string[] infoBlock = sectionBlocks[0];
            for (int i = 0; i < infoBlock.Length; i++)
            {
                string currentLine = infoBlock[i];
                if (currentLine.StartsWith("playerName "))
                {
                    playerName = currentLine.Substring("playerName ".Length);
                    if (!ValidateString(playerName, constants.maxPlayerNameLength, "playerName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("randomSeed "))
                {
                    string randomSeedString = currentLine.Substring("randomSeed ".Length);
                    int randomSeedNumber;
                    if (Int32.TryParse(randomSeedString, out randomSeedNumber))
                    {
                        if (!ValidateIntInRange(randomSeedNumber, constants.minRandomSeed, constants.maxRandomSeed, "randomSeed"))
                        {
                            return;
                        }
                        randomSeed = randomSeedNumber;
                    }
                    else
                    {
                        Debug.LogError("randomSeed is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("lastHub "))
                {
                    lastHub = currentLine.Substring("lastHub ".Length);
                    if (!ValidateString(lastHub, constants.maxStringLength, "lastHub"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("turns "))
                {
                    string turnsString = currentLine.Substring("turns ".Length);
                    int turnsNumber;
                    if (Int32.TryParse(turnsString, out turnsNumber))
                    {
                        if (!ValidateIntInRange(turnsNumber, constants.minTurns, constants.maxTurns, "turns"))
                        {
                            return;
                        }
                        turns = turnsNumber;
                    }
                    else
                    {
                        Debug.LogError("turns is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("deaths "))
                {
                    string deathsString = currentLine.Substring("deaths ".Length);
                    int deathsNumber;
                    if (Int32.TryParse(deathsString, out deathsNumber))
                    {
                        if (!ValidateIntInRange(deathsNumber, constants.minDeaths, constants.maxDeaths, "deaths"))
                        {
                            return;
                        }
                        deaths = deathsNumber;
                    }
                    else
                    {
                        Debug.LogError("deaths is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("defeatedEnemies "))
                {
                    string defeatedEnemiesString = currentLine.Substring("defeatedEnemies ".Length);
                    int defeatedEnemiesNumber;
                    if (Int32.TryParse(defeatedEnemiesString, out defeatedEnemiesNumber))
                    {
                        if (!ValidateIntInRange(defeatedEnemiesNumber, constants.minDefeatedEnemies, constants.maxDefeatedEnemies, "defeatedEnemies"))
                        {
                            return;
                        }
                        defeatedEnemies = defeatedEnemiesNumber;
                    }
                    else
                    {
                        Debug.LogError("defeatedEnemies is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("woodSalvage "))
                {
                    string woodSalvageString = currentLine.Substring("woodSalvage ".Length);
                    int woodSalvageNumber;
                    if (Int32.TryParse(woodSalvageString, out woodSalvageNumber))
                    {
                        if (!ValidateIntInRange(woodSalvageNumber, constants.minSalvage, constants.maxSalvage, "woodSalvage"))
                        {
                            return;
                        }
                        collectedSalvage.wood = woodSalvageNumber;
                    }
                    else
                    {
                        Debug.LogError("woodSalvage is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("metalSalvage "))
                {
                    string metalSalvageString = currentLine.Substring("metalSalvage ".Length);
                    int metalSalvageNumber;
                    if (Int32.TryParse(metalSalvageString, out metalSalvageNumber))
                    {
                        if (!ValidateIntInRange(metalSalvageNumber, constants.minSalvage, constants.maxSalvage, "metalSalvage"))
                        {
                            return;
                        }
                        collectedSalvage.metal = metalSalvageNumber;
                    }
                    else
                    {
                        Debug.LogError("metalSalvage is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("leatherSalvage "))
                {
                    string leatherSalvageString = currentLine.Substring("leatherSalvage ".Length);
                    int leatherSalvageNumber;
                    if (Int32.TryParse(leatherSalvageString, out leatherSalvageNumber))
                    {
                        if (!ValidateIntInRange(leatherSalvageNumber, constants.minSalvage, constants.maxSalvage, "leatherSalvage"))
                        {
                            return;
                        }
                        collectedSalvage.leather = leatherSalvageNumber;
                    }
                    else
                    {
                        Debug.LogError("leatherSalvage is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("knowledge "))
                {
                    string knowledgeString = currentLine.Substring("knowledge ".Length);
                    int knowledgeNumber;
                    if (Int32.TryParse(knowledgeString, out knowledgeNumber))
                    {
                        if (!ValidateIntInRange(knowledgeNumber, constants.minSalvage, constants.maxSalvage, "knowledge"))
                        {
                            return;
                        }
                        collectedSalvage.knowledge = knowledgeNumber;
                    }
                    else
                    {
                        Debug.LogError("knowledge is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("utilitySkillSlots "))
                {
                    string utilitySkillSlotsString = currentLine.Substring("utilitySkillSlots ".Length);
                    int utilitySkillSlotsNumber;
                    if (Int32.TryParse(utilitySkillSlotsString, out utilitySkillSlotsNumber))
                    {
                        if (!ValidateIntInRange(utilitySkillSlotsNumber, constants.minUtilitySkillSlots, constants.maxUtilitySkillSlots, "utilitySkillSlots"))
                        {
                            return;
                        }
                        utilitySkillSlots = utilitySkillSlotsNumber;
                    }
                    else
                    {
                        Debug.LogError("utilitySkillSlots is not a number");
                        return;
                    }
                }
            }
            // parse discovered hubs
            string[] discoveredHubsBlock = sectionBlocks[1];
            if (discoveredHubsBlock.Length > constants.maxDiscoveredHubs)
            {
                Debug.LogError("Too many discovered hubs: " + discoveredHubsBlock.Length + " (max: " + constants.maxDiscoveredHubs + ")");
                return;
            }
            discoveredHubs = new List<string>();
            for (int i = 0; i < discoveredHubsBlock.Length; i++)
            {
                string hubName = discoveredHubsBlock[i];
                if (!ValidateString(hubName, constants.maxStringLength, "hubName"))
                {
                    return;
                }
                discoveredHubs.Add(hubName);
            }
            // parse unlocked skills
            string[] unlockedSkillsBlock = sectionBlocks[2];
            if (unlockedSkillsBlock.Length > constants.maxUnlockedSkills)
            {
                Debug.LogError("Too many unlocked skills: " + unlockedSkillsBlock.Length + " (max: " + constants.maxUnlockedSkills + ")");
                return;
            }
            unlockedSkills = new List<string>();
            for (int i = 0; i < unlockedSkillsBlock.Length; i++)
            {
                string skillName = unlockedSkillsBlock[i];
                if (!ValidateResourceName(skillName, constants.validSkillNames, "skillName"))
                {
                    return;
                }
                unlockedSkills.Add(skillName);
            }
            // parse main hand weapon
            string[] mainHandWeaponBlock = sectionBlocks[3];
            mainHandWeapon = new WeaponData();
            for (int i = 0; i < mainHandWeaponBlock.Length; i++)
            {
                string currentLine = mainHandWeaponBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    mainHandWeapon.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(mainHandWeapon.itemName, constants.maxStringLength, "main hand itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("weaponType "))
                {
                    mainHandWeapon.weaponType = currentLine.Substring("weaponType ".Length);
                    if (!ValidateResourceName(mainHandWeapon.weaponType, constants.validWeaponTypes, "main hand weaponType"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damageString = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damageString, out damageNumber))
                    {
                        if (!ValidateIntInRange(damageNumber, constants.minWeaponDamage, constants.maxWeaponDamage, "main hand damage"))
                        {
                            return;
                        }
                        mainHandWeapon.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("main hand damage is not a number");
                        return;
                    }
                }
            }
            // parse off hand weapon
            string[] offHandWeaponBlock = sectionBlocks[4];
            offHandWeapon = new WeaponData();
            for (int i = 0; i < offHandWeaponBlock.Length; i++)
            {
                string currentLine = offHandWeaponBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    offHandWeapon.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(offHandWeapon.itemName, constants.maxStringLength, "off hand itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("weaponType "))
                {
                    offHandWeapon.weaponType = currentLine.Substring("weaponType ".Length);
                    if (!ValidateResourceName(offHandWeapon.weaponType, constants.validWeaponTypes, "off hand weaponType"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damageString = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damageString, out damageNumber))
                    {
                        if (!ValidateIntInRange(damageNumber, constants.minWeaponDamage, constants.maxWeaponDamage, "off hand damage"))
                        {
                            return;
                        }
                        offHandWeapon.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("off hand damage is not a number");
                        return;
                    }
                }
            }
            // parse amulet
            string[] amuletBlock = sectionBlocks[5];
            amulet = new AmuletData();
            for (int i = 0; i < amuletBlock.Length; i++)
            {
                string currentLine = amuletBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    amulet.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(amulet.itemName, constants.maxStringLength, "amulet itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("spellDamage "))
                {
                    string spellDamageString = currentLine.Substring("spellDamage ".Length);
                    int spellDamageNumber;
                    if (Int32.TryParse(spellDamageString, out spellDamageNumber))
                    {
                        if (!ValidateIntInRange(spellDamageNumber, constants.minSpellDamage, constants.maxSpellDamage, "amulet spellDamage"))
                        {
                            return;
                        }
                        amulet.spellDamage = spellDamageNumber;
                    }
                    else
                    {
                        Debug.LogError("amulet spellDamage is not a number");
                        return;
                    }
                }
            }
            // parse coat
            string[] coatBlock = sectionBlocks[6];
            coat = new CoatData();
            for (int i = 0; i < coatBlock.Length; i++)
            {
                string currentLine = coatBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    coat.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(coat.itemName, constants.maxStringLength, "coat itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        if (!ValidateIntInRange(armorNumber, constants.minArmor, constants.maxArmor, "coat armor"))
                        {
                            return;
                        }
                        coat.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("coat armor is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("health "))
                {
                    string healthString = currentLine.Substring("health ".Length);
                    int healthNumber;
                    if (Int32.TryParse(healthString, out healthNumber))
                    {
                        if (!ValidateIntInRange(healthNumber, constants.minHealthBonus, constants.maxHealthBonus, "coat health"))
                        {
                            return;
                        }
                        coat.health = healthNumber;
                    }
                    else
                    {
                        Debug.LogError("coat health is not a number");
                        return;
                    }
                }
            }
            // parse gloves
            string[] glovesBlock = sectionBlocks[7];
            gloves = new GlovesData();
            for (int i = 0; i < glovesBlock.Length; i++)
            {
                string currentLine = glovesBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    gloves.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(gloves.itemName, constants.maxStringLength, "gloves itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        if (!ValidateIntInRange(armorNumber, constants.minArmor, constants.maxArmor, "gloves armor"))
                        {
                            return;
                        }
                        gloves.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("gloves armor is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damageString = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damageString, out damageNumber))
                    {
                        if (!ValidateIntInRange(damageNumber, constants.minDamageBonus, constants.maxDamageBonus, "gloves damage"))
                        {
                            return;
                        }
                        gloves.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("gloves damage is not a number");
                        return;
                    }
                }
            }
            // parse pants
            string[] pantsBlock = sectionBlocks[8];
            pants = new PantsData();
            for (int i = 0; i < pantsBlock.Length; i++)
            {
                string currentLine = pantsBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    pants.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(pants.itemName, constants.maxStringLength, "pants itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        if (!ValidateIntInRange(armorNumber, constants.minArmor, constants.maxArmor, "pants armor"))
                        {
                            return;
                        }
                        pants.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("pants armor is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("pickupRadius "))
                {
                    string pickupRadiusString = currentLine.Substring("pickupRadius ".Length);
                    int pickupRadiusNumber;
                    if (Int32.TryParse(pickupRadiusString, out pickupRadiusNumber))
                    {
                        if (!ValidateIntInRange(pickupRadiusNumber, constants.minPickupRadius, constants.maxPickupRadius, "pants pickupRadius"))
                        {
                            return;
                        }
                        pants.pickupRadius = pickupRadiusNumber;
                    }
                    else
                    {
                        Debug.LogError("pants pickupRadius is not a number");
                        return;
                    }
                }
            }
            // parse boots
            string[] bootsBlock = sectionBlocks[9];
            boots = new BootsData();
            for (int i = 0; i < bootsBlock.Length; i++)
            {
                string currentLine = bootsBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    boots.itemName = currentLine.Substring("itemName ".Length);
                    if (!ValidateString(boots.itemName, constants.maxStringLength, "boots itemName"))
                    {
                        return;
                    }
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        if (!ValidateIntInRange(armorNumber, constants.minArmor, constants.maxArmor, "boots armor"))
                        {
                            return;
                        }
                        boots.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("boots armor is not a number");
                        return;
                    }
                }
                else if (currentLine.StartsWith("speed "))
                {
                    string speedString = currentLine.Substring("speed ".Length);
                    int speedNumber;
                    if (Int32.TryParse(speedString, out speedNumber))
                    {
                        if (!ValidateIntInRange(speedNumber, constants.minSpeedBonus, constants.maxSpeedBonus, "boots speed"))
                        {
                            return;
                        }
                        boots.speed = speedNumber;
                    }
                    else
                    {
                        Debug.LogError("boots speed is not a number");
                        return;
                    }
                }
            }
            // parse inventory
            string[] inventoryBlock = sectionBlocks[10];
            inventory = new List<InventoryItemData>();
            List<string[]> inventoryItemBlocks = new List<string[]>();
            List<string> currentSubArray = new List<string>();
            foreach (string line in inventoryBlock)
            {
                if (line == "")
                {
                    inventoryItemBlocks.Add(currentSubArray.ToArray());
                    currentSubArray.Clear();
                }
                else
                {
                    currentSubArray.Add(line);
                }
            }
            if (currentSubArray.Count > 0)
            {
                inventoryItemBlocks.Add(currentSubArray.ToArray());
            }
            if (inventoryItemBlocks.Count > constants.maxInventorySize)
            {
                Debug.LogError("Too many inventory items: " + inventoryItemBlocks.Count + " (max: " + constants.maxInventorySize + ")");
                return;
            }
            foreach (string[] itemBlock in inventoryItemBlocks)
            {
                // first line should define itemType
                string firstLine = itemBlock[0];
                if (firstLine.StartsWith("itemType "))
                {
                    string itemType = firstLine.Substring("itemType ".Length);
                    if (!ValidateResourceName(itemType, constants.validItemTypes, "itemType"))
                    {
                        return;
                    }
                    switch (itemType)
                    {
                        case "Weapon":
                            WeaponData inventoryWeapon = new WeaponData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryWeapon.itemName = currentLine.Substring("itemName ".Length);
                                    if (!ValidateString(inventoryWeapon.itemName, constants.maxStringLength, "inventory weapon itemName"))
                                    {
                                        return;
                                    }
                                }
                                else if (currentLine.StartsWith("weaponType "))
                                {
                                    inventoryWeapon.weaponType = currentLine.Substring("weaponType ".Length);
                                    if (!ValidateResourceName(inventoryWeapon.weaponType, constants.validWeaponTypes, "inventory weapon weaponType"))
                                    {
                                        return;
                                    }
                                }
                                else if (currentLine.StartsWith("damage "))
                                {
                                    string damageString = currentLine.Substring("damage ".Length);
                                    int damageNumber;
                                    if (Int32.TryParse(damageString, out damageNumber))
                                    {
                                        if (!ValidateIntInRange(damageNumber, constants.minWeaponDamage, constants.maxWeaponDamage, "inventory weapon damage"))
                                        {
                                            return;
                                        }
                                        inventoryWeapon.damage = damageNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory weapon damage is not a number");
                                        return;
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        if (!ValidateIntInRange(inventoryPositionNumber, constants.minInventoryPosition, constants.maxInventoryPosition, "inventory weapon inventoryPosition"))
                                        {
                                            return;
                                        }
                                        inventoryWeapon.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory weapon inventoryPosition is not a number");
                                        return;
                                    }
                                }
                            }
                            inventory.Add(inventoryWeapon);
                            break;
                        case "Amulet":
                            AmuletData inventoryAmulet = new AmuletData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryAmulet.itemName = currentLine.Substring("itemName ".Length);
                                }
                                else if (currentLine.StartsWith("spellDamage "))
                                {
                                    string spellDamageString = currentLine.Substring("spellDamage ".Length);
                                    int spellDamageNumber;
                                    if (Int32.TryParse(spellDamageString, out spellDamageNumber))
                                    {
                                        inventoryAmulet.spellDamage = spellDamageNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory amulet spellDamage is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        inventoryAmulet.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory amulet inventoryPosition is not a number");
                                    }
                                }
                            }
                            inventory.Add(inventoryAmulet);
                            break;
                        case "Coat":
                            CoatData inventoryCoat = new CoatData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryCoat.itemName = currentLine.Substring("itemName ".Length);
                                }
                                else if (currentLine.StartsWith("armor "))
                                {
                                    string armorString = currentLine.Substring("armor ".Length);
                                    int armorNumber;
                                    if (Int32.TryParse(armorString, out armorNumber))
                                    {
                                        inventoryCoat.armor = armorNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory coat armor is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("health "))
                                {
                                    string healthString = currentLine.Substring("health ".Length);
                                    int healthNumber;
                                    if (Int32.TryParse(healthString, out healthNumber))
                                    {
                                        inventoryCoat.health = healthNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory coat health is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        inventoryCoat.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory coat inventoryPosition is not a number");
                                    }
                                }
                            }
                            inventory.Add(inventoryCoat);
                            break;
                        case "Gloves":
                            GlovesData inventoryGloves = new GlovesData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryGloves.itemName = currentLine.Substring("itemName ".Length);
                                }
                                else if (currentLine.StartsWith("armor "))
                                {
                                    string armorString = currentLine.Substring("armor ".Length);
                                    int armorNumber;
                                    if (Int32.TryParse(armorString, out armorNumber))
                                    {
                                        inventoryGloves.armor = armorNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory gloves armor is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("damage "))
                                {
                                    string damageString = currentLine.Substring("damage ".Length);
                                    int damageNumber;
                                    if (Int32.TryParse(damageString, out damageNumber))
                                    {
                                        inventoryGloves.damage = damageNumber;
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        inventoryGloves.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory gloves inventoryPosition is not a number");
                                    }
                                }
                            }
                            inventory.Add(inventoryGloves);
                            break;
                        case "Pants":
                            PantsData inventoryPants = new PantsData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryPants.itemName = currentLine.Substring("itemName ".Length);
                                }
                                else if (currentLine.StartsWith("armor "))
                                {
                                    string armorString = currentLine.Substring("armor ".Length);
                                    int armorNumber;
                                    if (Int32.TryParse(armorString, out armorNumber))
                                    {
                                        inventoryPants.armor = armorNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory pants armor is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("pickupRadius "))
                                {
                                    string pickupRadiusString = currentLine.Substring("pickupRadius ".Length);
                                    int pickupRadiusNumber;
                                    if (Int32.TryParse(pickupRadiusString, out pickupRadiusNumber))
                                    {
                                        inventoryPants.pickupRadius = pickupRadiusNumber;
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        inventoryPants.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory pants inventoryPosition is not a number");
                                    }
                                }
                            }
                            inventory.Add(inventoryPants);
                            break;
                        case "Boots":
                            BootsData inventoryBoots = new BootsData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryBoots.itemName = currentLine.Substring("itemName ".Length);
                                }
                                else if (currentLine.StartsWith("armor "))
                                {
                                    string armorString = currentLine.Substring("armor ".Length);
                                    int armorNumber;
                                    if (Int32.TryParse(armorString, out armorNumber))
                                    {
                                        inventoryBoots.armor = armorNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory boots armor is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("speed "))
                                {
                                    string speedString = currentLine.Substring("speed ".Length);
                                    int speedNumber;
                                    if (Int32.TryParse(speedString, out speedNumber))
                                    {
                                        inventoryBoots.speed = speedNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory boots speed is not a number");
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        inventoryBoots.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory boots inventoryPosition is not a number");
                                    }
                                }
                            }
                            inventory.Add(inventoryBoots);
                            break;
                        case "Tome":
                            TomeData inventoryTome = new TomeData();
                            for (int i = 1; i < itemBlock.Length; i++)
                            {
                                string currentLine = itemBlock[i];
                                if (currentLine.StartsWith("itemName "))
                                {
                                    inventoryTome.itemName = currentLine.Substring("itemName ".Length);
                                    if (!ValidateString(inventoryTome.itemName, constants.maxStringLength, "inventory tome itemName"))
                                    {
                                        return;
                                    }
                                }
                                else if (currentLine.StartsWith("skillName "))
                                {
                                    inventoryTome.skillName = currentLine.Substring("skillName ".Length);
                                    if (!ValidateResourceName(inventoryTome.skillName, constants.validSkillNames, "inventory tome skillName"))
                                    {
                                        return;
                                    }
                                }
                                else if (currentLine.StartsWith("inventoryPosition "))
                                {
                                    string inventoryPositionString = currentLine.Substring("inventoryPosition ".Length);
                                    int inventoryPositionNumber;
                                    if (Int32.TryParse(inventoryPositionString, out inventoryPositionNumber))
                                    {
                                        if (!ValidateIntInRange(inventoryPositionNumber, constants.minInventoryPosition, constants.maxInventoryPosition, "inventory tome inventoryPosition"))
                                        {
                                            return;
                                        }
                                        inventoryTome.inventoryPosition = inventoryPositionNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory tome inventoryPosition is not a number");
                                        return;
                                    }
                                }
                            }
                            inventory.Add(inventoryTome);
                            break;
                    }
                }
                else
                {
                    Debug.LogError("item in inventory is not specifying its item type");
                }
            }
            // parse utility skills
            string[] utilitySkillsBlock = sectionBlocks[11];
            utilitySkills = new string[5];
            for (int i = 0; i < utilitySkillsBlock.Length; i++)
            {
                string currentLine = utilitySkillsBlock[i];
                int firstSpaceIndex = currentLine.IndexOf(' ');
                if (firstSpaceIndex > 0 && firstSpaceIndex < currentLine.Length - 1)
                {
                    string skillNumberString = currentLine.Substring(0, firstSpaceIndex);
                    string skillName = currentLine.Substring(firstSpaceIndex + 1);
                    if (!ValidateResourceName(skillName, constants.validSkillNames, "utility skill skillName"))
                    {
                        return;
                    }
                    int skillNumber;
                    if (Int32.TryParse(skillNumberString, out skillNumber))
                    {
                        if (4 <= skillNumber && skillNumber <= 8) // to-do - think about this
                        {
                            utilitySkills[skillNumber - 4] = skillName;
                        }
                        else
                        {
                            Debug.LogError("utility skill number out of range: " + skillNumber);
                            return;
                        }
                    }
                    else
                    {
                        Debug.LogError("utility skill number is not a number");
                        return;
                    }
                }
            }
            // parse clone data
            string[] cloneDataBlock = sectionBlocks[12];
            allCloneData = new Dictionary<string, CloneData>();
            List<string[]> cloneDataItemBlocks = new List<string[]>();
            List<string> currentCloneSubArray = new List<string>();
            foreach (string line in cloneDataBlock)
            {
                if (line == "")
                {
                    if (currentCloneSubArray.Count > 0)
                    {
                        cloneDataItemBlocks.Add(currentCloneSubArray.ToArray());
                        currentCloneSubArray.Clear();
                    }
                }
                else
                {
                    currentCloneSubArray.Add(line);
                }
            }
            if (currentCloneSubArray.Count > 0)
            {
                cloneDataItemBlocks.Add(currentCloneSubArray.ToArray());
            }
            if (cloneDataItemBlocks.Count > constants.maxClones)
            {
                Debug.LogError("Too many clones: " + cloneDataItemBlocks.Count + " (max: " + constants.maxClones + ")");
                return;
            }
            foreach (string[] cloneBlock in cloneDataItemBlocks)
            {
                string cloneName = null;
                CloneData cloneData = new CloneData();
                cloneData.totalSalvage = new Salvage();

                for (int i = 0; i < cloneBlock.Length; i++)
                {
                    string currentLine = cloneBlock[i];
                    if (currentLine.StartsWith("cloneName "))
                    {
                        cloneName = currentLine.Substring("cloneName ".Length);
                        if (!ValidateString(cloneName, constants.maxStringLength, "cloneName"))
                        {
                            return;
                        }
                    }
                    else if (currentLine.StartsWith("wood "))
                    {
                        string woodString = currentLine.Substring("wood ".Length);
                        int woodNumber;
                        if (Int32.TryParse(woodString, out woodNumber))
                        {
                            if (!ValidateIntInRange(woodNumber, constants.minSalvage, constants.maxSalvage, "clone data wood"))
                            {
                                return;
                            }
                            cloneData.totalSalvage.wood = woodNumber;
                        }
                        else
                        {
                            Debug.LogError("clone data wood is not a number");
                            return;
                        }
                    }
                    else if (currentLine.StartsWith("metal "))
                    {
                        string metalString = currentLine.Substring("metal ".Length);
                        int metalNumber;
                        if (Int32.TryParse(metalString, out metalNumber))
                        {
                            if (!ValidateIntInRange(metalNumber, constants.minSalvage, constants.maxSalvage, "clone data metal"))
                            {
                                return;
                            }
                            cloneData.totalSalvage.metal = metalNumber;
                        }
                        else
                        {
                            Debug.LogError("clone data metal is not a number");
                            return;
                        }
                    }
                    else if (currentLine.StartsWith("leather "))
                    {
                        string leatherString = currentLine.Substring("leather ".Length);
                        int leatherNumber;
                        if (Int32.TryParse(leatherString, out leatherNumber))
                        {
                            if (!ValidateIntInRange(leatherNumber, constants.minSalvage, constants.maxSalvage, "clone data leather"))
                            {
                                return;
                            }
                            cloneData.totalSalvage.leather = leatherNumber;
                        }
                        else
                        {
                            Debug.LogError("clone data leather is not a number");
                            return;
                        }
                    }
                    else if (currentLine.StartsWith("cloth "))
                    {
                        string clothString = currentLine.Substring("cloth ".Length);
                        int clothNumber;
                        if (Int32.TryParse(clothString, out clothNumber))
                        {
                            if (!ValidateIntInRange(clothNumber, constants.minSalvage, constants.maxSalvage, "clone data cloth"))
                            {
                                return;
                            }
                            cloneData.totalSalvage.cloth = clothNumber;
                        }
                        else
                        {
                            Debug.LogError("clone data cloth is not a number");
                            return;
                        }
                    }
                    else if (currentLine.StartsWith("knowledge "))
                    {
                        string knowledgeString = currentLine.Substring("knowledge ".Length);
                        int knowledgeNumber;
                        if (Int32.TryParse(knowledgeString, out knowledgeNumber))
                        {
                            if (!ValidateIntInRange(knowledgeNumber, constants.minSalvage, constants.maxSalvage, "clone data knowledge"))
                            {
                                return;
                            }
                            cloneData.totalSalvage.knowledge = knowledgeNumber;
                        }
                        else
                        {
                            Debug.LogError("clone data knowledge is not a number");
                            return;
                        }
                    }
                    else if (currentLine.StartsWith("turnsToComplete "))
                    {
                        string turnsString = currentLine.Substring("turnsToComplete ".Length);
                        int turnsNumber;
                        if (Int32.TryParse(turnsString, out turnsNumber))
                        {
                            if (!ValidateIntInRange(turnsNumber, constants.minTurns, constants.maxTurns, "clone data turnsToComplete"))
                            {
                                return;
                            }
                            cloneData.turnsToComplete = turnsNumber;
                        }
                        else
                        {
                            Debug.LogError("clone data turnsToComplete is not a number");
                            return;
                        }
                    }
                }

                if (cloneName != null)
                {
                    allCloneData[cloneName] = cloneData;
                }
                else
                {
                    Debug.LogError("clone data entry missing cloneName");
                }
            }
        }
    }

    public void SavePlayerData(string savePath)
    {
        string saveData = "";

        // write info section
        saveData += "Info\n";
        saveData += "playerName " + playerName + "\n";
        saveData += "randomSeed " + randomSeed.ToString() + "\n";
        saveData += "lastHub " + lastHub + "\n";
        saveData += "turns " + turns.ToString() + "\n";
        saveData += "deaths " + deaths.ToString() + "\n";
        saveData += "defeatedEnemies " + defeatedEnemies.ToString() + "\n";
        saveData += "woodSalvage " + collectedSalvage.wood.ToString() + "\n";
        saveData += "metalSalvage " + collectedSalvage.metal.ToString() + "\n";
        saveData += "leatherSalvage " + collectedSalvage.leather.ToString() + "\n";
        saveData += "knowledge " + collectedSalvage.knowledge.ToString() + "\n";
        saveData += "utilitySkillSlots " + utilitySkillSlots.ToString() + "\n";
        saveData += "\n";

        // write discovered hubs section
        saveData += "Discovered Hubs\n";
        for (int i = 0; i < discoveredHubs.Count; i++)
        {
            saveData += discoveredHubs[i] + "\n";
        }
        saveData += "\n";

        // write unlocked skills section
        saveData += "Unlocked Skills\n";
        for (int i = 0; i < unlockedSkills.Count; i++)
        {
            saveData += unlockedSkills[i] + "\n";
        }
        saveData += "\n";

        // write main hand weapon section
        saveData += "Main Hand Weapon\n";
        if (mainHandWeapon != null && mainHandWeapon.itemName != null)
        {
            saveData += "itemName " + mainHandWeapon.itemName + "\n";
            saveData += "weaponType " + mainHandWeapon.weaponType + "\n";
            saveData += "damage " + mainHandWeapon.damage.ToString() + "\n";
        }
        saveData += "\n";

        // write off hand weapon section
        saveData += "Off Hand Weapon\n";
        if (offHandWeapon != null && offHandWeapon.itemName != null)
        {
            saveData += "itemName " + offHandWeapon.itemName + "\n";
            saveData += "weaponType " + offHandWeapon.weaponType + "\n";
            saveData += "damage " + offHandWeapon.damage.ToString() + "\n";
        }
        saveData += "\n";

        // write amulet section
        saveData += "Amulet\n";
        if (amulet != null && amulet.itemName != null)
        {
            saveData += "itemName " + amulet.itemName + "\n";
            saveData += "spellDamage " + amulet.spellDamage.ToString() + "\n";
        }
        saveData += "\n";

        // write coat section
        saveData += "Coat\n";
        if (coat != null && coat.itemName != null)
        {
            saveData += "itemName " + coat.itemName + "\n";
            saveData += "armor " + coat.armor.ToString() + "\n";
            saveData += "health " + coat.health.ToString() + "\n";
        }
        saveData += "\n";

        // write gloves section
        saveData += "Gloves\n";
        if (gloves != null && gloves.itemName != null)
        {
            saveData += "itemName " + gloves.itemName + "\n";
            saveData += "armor " + gloves.armor.ToString() + "\n";
            saveData += "damage " + gloves.damage.ToString() + "\n";
        }
        saveData += "\n";

        // write pants section
        saveData += "Pants\n";
        if (pants != null && pants.itemName != null)
        {
            saveData += "itemName " + pants.itemName + "\n";
            saveData += "armor " + pants.armor.ToString() + "\n";
            saveData += "pickupRadius " + pants.pickupRadius.ToString() + "\n";
        }
        saveData += "\n";

        // write boots section
        saveData += "Boots\n";
        if (boots != null && boots.itemName != null)
        {
            saveData += "itemName " + boots.itemName + "\n";
            saveData += "armor " + boots.armor.ToString() + "\n";
            saveData += "speed " + boots.speed.ToString() + "\n";
        }
        saveData += "\n";

        // write inventory section
        saveData += "Inventory\n";
        for (int i = 0; i < inventory.Count; i++)
        {
            InventoryItemData item = inventory[i];
            if (item is WeaponData)
            {
                WeaponData weaponItem = (WeaponData)item;
                saveData += "itemType Weapon\n";
                saveData += "itemName " + weaponItem.itemName + "\n";
                saveData += "weaponType " + weaponItem.weaponType + "\n";
                saveData += "damage " + weaponItem.damage.ToString() + "\n";
                saveData += "inventoryPosition " + weaponItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
            else if (item is AmuletData)
            {
                AmuletData amuletItem = (AmuletData)item;
                saveData += "itemType Amulet\n";
                saveData += "itemName " + amuletItem.itemName + "\n";
                saveData += "spellDamage " + amuletItem.spellDamage.ToString() + "\n";
                saveData += "inventoryPosition " + amuletItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
            else if (item is CoatData)
            {
                CoatData coatItem = (CoatData)item;
                saveData += "itemType Coat\n";
                saveData += "itemName " + coatItem.itemName + "\n";
                saveData += "armor " + coatItem.armor.ToString() + "\n";
                saveData += "health " + coatItem.health.ToString() + "\n";
                saveData += "inventoryPosition " + coatItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
            else if (item is GlovesData)
            {
                GlovesData glovesItem = (GlovesData)item;
                saveData += "itemType Gloves\n";
                saveData += "itemName " + glovesItem.itemName + "\n";
                saveData += "armor " + glovesItem.armor.ToString() + "\n";
                saveData += "damage " + glovesItem.damage.ToString() + "\n";
                saveData += "inventoryPosition " + glovesItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
            else if (item is PantsData)
            {
                PantsData pantsItem = (PantsData)item;
                saveData += "itemType Pants\n";
                saveData += "itemName " + pantsItem.itemName + "\n";
                saveData += "armor " + pantsItem.armor.ToString() + "\n";
                saveData += "pickupRadius " + pantsItem.pickupRadius.ToString() + "\n";
                saveData += "inventoryPosition " + pantsItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
            else if (item is BootsData)
            {
                BootsData bootsItem = (BootsData)item;
                saveData += "itemType Boots\n";
                saveData += "itemName " + bootsItem.itemName + "\n";
                saveData += "armor " + bootsItem.armor.ToString() + "\n";
                saveData += "speed " + bootsItem.speed.ToString() + "\n";
                saveData += "inventoryPosition " + bootsItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
            else if (item is TomeData)
            {
                TomeData tomeItem = (TomeData)item;
                saveData += "itemType Tome\n";
                saveData += "itemName " + tomeItem.itemName + "\n";
                saveData += "skillName " + tomeItem.skillName + "\n";
                saveData += "inventoryPosition " + tomeItem.inventoryPosition.ToString() + "\n";
                saveData += "\n";
            }
        }
        if (inventory.Count == 0)
        {
            saveData += "\n";
        }

        // write utility skills section
        saveData += "Utility Skills\n";
        for (int i = 0; i < utilitySkills.Length; i++)
        {
            if (utilitySkills[i] != null)
            {
                int skillNumber = i + 4;
                saveData += skillNumber.ToString() + " " + utilitySkills[i] + "\n";
            }
        }
        saveData += "\n";

        // write clone data section
        saveData += "Clone Data\n";
        foreach (var cloneEntry in allCloneData)
        {
            string cloneName = cloneEntry.Key;
            CloneData cloneData = cloneEntry.Value;
            saveData += "cloneName " + cloneName + "\n";
            if (cloneData.totalSalvage != null)
            {
                saveData += "wood " + cloneData.totalSalvage.wood.ToString() + "\n";
                saveData += "metal " + cloneData.totalSalvage.metal.ToString() + "\n";
                saveData += "leather " + cloneData.totalSalvage.leather.ToString() + "\n";
                saveData += "cloth " + cloneData.totalSalvage.cloth.ToString() + "\n";
                saveData += "knowledge " + cloneData.totalSalvage.knowledge.ToString() + "\n";
            }
            saveData += "turnsToComplete " + cloneData.turnsToComplete.ToString() + "\n";
            saveData += "\n";
        }
        if (allCloneData.Count == 0)
        {
            saveData += "\n";
        }

        // write to file or download
#if UNITY_WEBGL && !UNITY_EDITOR
        // in WebGL, trigger a browser download
        string filename = savePath + ".txt";
        DownloadFile(filename, saveData);
#else
        // in standalone builds, save to file system
        string fullPath = Application.persistentDataPath + "/" + savePath + ".txt";
        try
        {
            File.WriteAllText(fullPath, saveData);
        }
        catch (Exception e)
        {
            Debug.LogError("Failed to save player data: " + e.Message);
        }
#endif
    }

    public IEnumerator BuildPlayerFromData(GameObject player)
    {
        finishedBuilding = false;
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        while (!playerScript.finishedBuilding)
        {
            yield return null;
        }
        Transform playerMainHand = playerScript.mainHand;
        Transform playerOffHand = playerScript.offHand;
        Transform playerNeck = playerScript.neck;
        Transform playerBody = playerScript.body;
        Transform playerHands = playerScript.hands;
        Transform playerLegs = playerScript.legs;
        Transform playerFeet = playerScript.feet;
        Transform playerInventory = playerScript.inventory;
        Transform playerUtilitySkills = playerScript.utilitySkills;
        // clear out player
        void ClearChildren(Transform playerPart)
        {
            for (int i = playerPart.childCount - 1; i >= 0; i--)
            {
                GameObject partChild = playerPart.GetChild(i).gameObject;
                DestroyImmediate(partChild);
            }
        }
        ClearChildren(playerMainHand);
        ClearChildren(playerOffHand);
        ClearChildren(playerNeck);
        ClearChildren(playerBody);
        ClearChildren(playerHands);
        ClearChildren(playerLegs);
        ClearChildren(playerFeet);
        ClearChildren(playerInventory);
        ClearChildren(playerUtilitySkills);
        // update player info
        playerScript.utilitySkillSlots = utilitySkillSlots;
        // create player gear
        if (mainHandWeapon.itemName != null)
        {
            GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/Items/" + mainHandWeapon.weaponType);
            if (weaponPrefab != null)
            {
                GameObject newWeapon = Instantiate(weaponPrefab, playerMainHand);
                WeaponScript weaponScript = newWeapon.GetComponent<WeaponScript>();
                weaponScript.SetItemName(mainHandWeapon.itemName);
                weaponScript.SetDamage(mainHandWeapon.damage);
            }
            else
            {
                Debug.LogError("unrecognized main hand weapon type");
            }
        }
        if (offHandWeapon.itemName != null)
        {
            GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/Items/" + offHandWeapon.weaponType);
            if (weaponPrefab != null)
            {
                GameObject newWeapon = Instantiate(weaponPrefab, playerOffHand);
                WeaponScript weaponScript = newWeapon.GetComponent<WeaponScript>();
                weaponScript.SetItemName(offHandWeapon.itemName);
                weaponScript.SetDamage(offHandWeapon.damage);
            }
            else
            {
                Debug.LogError("unrecognized main hand weapon type");
            }
        }
        // wait one frame for weapons' Start() methods to run and create their skills
        yield return null;
        if (amulet.itemName != null)
        {
            GameObject amuletPrefab = Resources.Load<GameObject>("Prefabs/Items/Amulet");
            GameObject newAmulet = Instantiate(amuletPrefab, playerNeck);
            AmuletScript amuletScript = newAmulet.GetComponent<AmuletScript>();
            amuletScript.itemName = amulet.itemName;
            amuletScript.spellDamage = amulet.spellDamage;
        }
        if (coat.itemName != null)
        {
            GameObject coatPrefab = Resources.Load<GameObject>("Prefabs/Items/Coat");
            GameObject newCoat = Instantiate(coatPrefab, playerBody);
            CoatScript coatScript = newCoat.GetComponent<CoatScript>();
            coatScript.itemName = coat.itemName;
            coatScript.armorBonus = coat.armor;
            coatScript.healthBonus = coat.health;
        }
        if (gloves.itemName != null)
        {
            GameObject glovesPrefab = Resources.Load<GameObject>("Prefabs/Items/Gloves");
            GameObject newGloves = Instantiate(glovesPrefab, playerHands);
            GlovesScript glovesScript = newGloves.GetComponent<GlovesScript>();
            glovesScript.itemName = gloves.itemName;
            glovesScript.armorBonus = gloves.armor;
            glovesScript.damageBonus = gloves.damage;
        }
        if (pants.itemName != null)
        {
            GameObject pantsPrefab = Resources.Load<GameObject>("Prefabs/Items/Pants");
            GameObject newPants = Instantiate(pantsPrefab, playerLegs);
            PantsScript pantsScript = newPants.GetComponent<PantsScript>();
            pantsScript.itemName = pants.itemName;
            pantsScript.armorBonus = pants.armor;
            pantsScript.pickupRadius = pants.pickupRadius;
        }

        if (boots.itemName != null)
        {
            GameObject bootsPrefab = Resources.Load<GameObject>("Prefabs/Items/Boots");
            GameObject newBoots = Instantiate(bootsPrefab, playerFeet);
            BootsScript bootsScript = newBoots.GetComponent<BootsScript>();
            bootsScript.itemName = boots.itemName;
            bootsScript.armorBonus = boots.armor;
            bootsScript.speedBonus = boots.speed;
        }
        // create player inventory
        foreach (InventoryItemData inventoryItem in inventory)
        {
            if (inventoryItem is WeaponData)
            {
                WeaponData inventoryWeapon = (WeaponData)inventoryItem;
                GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/Items/" + inventoryWeapon.weaponType);
                GameObject newWeapon = Instantiate(weaponPrefab, playerInventory);
                WeaponScript weaponScript = newWeapon.GetComponent<WeaponScript>();
                weaponScript.SetItemName(inventoryWeapon.itemName);
                weaponScript.SetDamage(inventoryWeapon.damage);
                ItemScript itemScript = newWeapon.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryWeapon.inventoryPosition;
            }
            else if (inventoryItem is AmuletData)
            {
                AmuletData inventoryAmulet = (AmuletData)inventoryItem;
                GameObject amuletPrefab = Resources.Load<GameObject>("Prefabs/Items/Amulet");
                GameObject newAmulet = Instantiate(amuletPrefab, playerInventory);
                AmuletScript amuletScript = newAmulet.GetComponent<AmuletScript>();
                amuletScript.itemName = inventoryAmulet.itemName;
                amuletScript.spellDamage = inventoryAmulet.spellDamage;
                ItemScript itemScript = newAmulet.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryAmulet.inventoryPosition;
            }
            else if (inventoryItem is CoatData)
            {
                CoatData inventoryCoat = (CoatData)inventoryItem;
                GameObject coatPrefab = Resources.Load<GameObject>("Prefabs/Items/Coat");
                GameObject newCoat = Instantiate(coatPrefab, playerInventory);
                CoatScript coatScript = newCoat.GetComponent<CoatScript>();
                coatScript.itemName = inventoryCoat.itemName;
                coatScript.armorBonus = inventoryCoat.armor;
                coatScript.healthBonus = inventoryCoat.health;
                ItemScript itemScript = newCoat.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryCoat.inventoryPosition;
            }
            else if (inventoryItem is GlovesData)
            {
                GlovesData inventoryGloves = (GlovesData)inventoryItem;
                GameObject glovesPrefab = Resources.Load<GameObject>("Prefabs/Items/Gloves");
                GameObject newGloves = Instantiate(glovesPrefab, playerInventory);
                GlovesScript glovesScript = newGloves.GetComponent<GlovesScript>();
                glovesScript.itemName = inventoryGloves.itemName;
                glovesScript.armorBonus = inventoryGloves.armor;
                glovesScript.damageBonus = inventoryGloves.damage;
                ItemScript itemScript = newGloves.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryGloves.inventoryPosition;
            }
            else if (inventoryItem is PantsData)
            {
                PantsData inventoryPants = (PantsData)inventoryItem;
                GameObject pantsPrefab = Resources.Load<GameObject>("Prefabs/Items/Pants");
                GameObject newPants = Instantiate(pantsPrefab, playerInventory);
                PantsScript pantsScript = newPants.GetComponent<PantsScript>();
                pantsScript.itemName = inventoryPants.itemName;
                pantsScript.armorBonus = inventoryPants.armor;
                pantsScript.pickupRadius = inventoryPants.pickupRadius;
                ItemScript itemScript = newPants.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryPants.inventoryPosition;
            }
            else if (inventoryItem is BootsData)
            {
                BootsData inventoryBoots = (BootsData)inventoryItem;
                GameObject bootsPrefab = Resources.Load<GameObject>("Prefabs/Items/Boots");
                GameObject newBoots = Instantiate(bootsPrefab, playerInventory);
                BootsScript bootsScript = newBoots.GetComponent<BootsScript>();
                bootsScript.itemName = inventoryBoots.itemName;
                bootsScript.armorBonus = inventoryBoots.armor;
                bootsScript.speedBonus = inventoryBoots.speed;
                ItemScript itemScript = newBoots.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryBoots.inventoryPosition;
            }
            else if (inventoryItem is TomeData)
            {
                TomeData inventoryTome = (TomeData)inventoryItem;
                GameObject tomePrefab = Resources.Load<GameObject>("Prefabs/Items/Skill Tome");
                GameObject newTome = Instantiate(tomePrefab, playerInventory);
                SkillTomeScript tomeScript = newTome.GetComponent<SkillTomeScript>();
                tomeScript.skillName = inventoryTome.skillName;
                ItemScript itemScript = newTome.GetComponent<ItemScript>();
                itemScript.inventoryPosition = inventoryTome.inventoryPosition;
            }
        }
        // create player utility skills
        for (int i = 0; i < utilitySkills.Length; i++)
        {
            if (utilitySkills[i] != null)
            {
                string skillName = utilitySkills[i];
                if (unlockedSkills.Contains(skillName))
                {
                    GameObject skillPrefab = Resources.Load<GameObject>("Prefabs/Skills/" + skillName);
                    GameObject newSkill = Instantiate(skillPrefab, playerUtilitySkills);
                    Skill skillScript = newSkill.GetComponent<Skill>();
                    skillScript.skillBarPosition = i + 4;
                }
                else
                {
                    Debug.LogError("player has not unlocked the skill " + skillName);
                }
            }
        }
        // wait one frame for utility skills' Start() methods to run and load their sprites
        yield return null;
        finishedBuilding = true;
    }
    
    public void BuildDataFromPlayer(GameObject player)
    {
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        // get player info
        utilitySkillSlots = playerScript.utilitySkillSlots;
        // get player gear
        GameObject playerMainHandWeapon = playerScript.mainHandWeapon;
        if (playerMainHandWeapon != null)
        {
            WeaponScript playerMainHandWeaponScript = playerMainHandWeapon.GetComponent<WeaponScript>();
            mainHandWeapon = new WeaponData();
            mainHandWeapon.itemName = playerMainHandWeaponScript.ItemName();
            mainHandWeapon.weaponType = playerMainHandWeaponScript.ItemSubType();
            mainHandWeapon.damage = playerMainHandWeaponScript.GetDamage();
        }
        else
        {
            mainHandWeapon = new WeaponData();
        }
        GameObject playerOffHandWeapon = playerScript.offHandWeapon;
        if (playerOffHandWeapon != null)
        {
            WeaponScript playerOffHandWeaponScript = playerOffHandWeapon.GetComponent<WeaponScript>();
            offHandWeapon = new WeaponData();
            offHandWeapon.itemName = playerOffHandWeaponScript.ItemName();
            offHandWeapon.weaponType = playerOffHandWeaponScript.ItemSubType();
            offHandWeapon.damage = playerOffHandWeaponScript.GetDamage();
        }
        else
        {
            offHandWeapon = new WeaponData();
        }
        GameObject playerAmulet = playerScript.amulet;
        if (playerAmulet != null)
        {
            AmuletScript playerAmuletScript = playerAmulet.GetComponent<AmuletScript>();
            amulet = new AmuletData();
            amulet.itemName = playerAmuletScript.itemName;
            amulet.spellDamage = playerAmuletScript.spellDamage;
        }
        else
        {
            amulet = new AmuletData();
        }
        GameObject playerCoat = playerScript.coat;
        if (playerCoat != null)
        {
            CoatScript playerCoatScript = playerCoat.GetComponent<CoatScript>();
            coat = new CoatData();
            coat.itemName = playerCoatScript.itemName;
            coat.armor = playerCoatScript.armorBonus;
            coat.health = playerCoatScript.healthBonus;
        }
        else
        {
            coat = new CoatData();
        }
        GameObject playerGloves = playerScript.gloves;
        if (playerGloves != null)
        {
            GlovesScript playerGlovesScript = playerGloves.GetComponent<GlovesScript>();
            gloves = new GlovesData();
            gloves.itemName = playerGlovesScript.itemName;
            gloves.armor = playerGlovesScript.armorBonus;
            gloves.damage = playerGlovesScript.damageBonus;
        }
        else
        {
            gloves = new GlovesData();
        }
        GameObject playerPants = playerScript.pants;
        if (playerPants != null)
        {
            PantsScript playerPantsScript = playerPants.GetComponent<PantsScript>();
            pants = new PantsData();
            pants.itemName = playerPantsScript.itemName;
            pants.armor = playerPantsScript.armorBonus;
            pants.pickupRadius = playerPantsScript.pickupRadius;
        }
        else
        {
            pants = new PantsData();
        }
        GameObject playerBoots = playerScript.boots;
        if (playerBoots != null)
        {
            BootsScript playerBootsScript = playerBoots.GetComponent<BootsScript>();
            boots = new BootsData();
            boots.itemName = playerBootsScript.itemName;
            boots.armor = playerBootsScript.armorBonus;
            boots.speed = playerBootsScript.speedBonus;
        }
        else
        {
            boots = new BootsData();
        }
        // get player inventory
        Transform playerInventory = playerScript.inventory;
        inventory = new List<InventoryItemData>();
        for (int i = 0; i < playerInventory.childCount; i++)
        {
            GameObject playerInventoryItem = playerInventory.GetChild(i).gameObject;
            ItemScript playerInventoryItemScript = playerInventoryItem.GetComponent<ItemScript>();
            string itemType = playerInventoryItemScript.ItemType();
            switch (itemType)
            {
                case "Weapon":
                    WeaponScript playerInventoryWeaponScript = playerInventoryItem.GetComponent<WeaponScript>();
                    WeaponData weaponData = new WeaponData();
                    weaponData.itemName = playerInventoryWeaponScript.ItemName();
                    weaponData.inventoryPosition = playerInventoryWeaponScript.inventoryPosition;
                    weaponData.weaponType = playerInventoryWeaponScript.ItemSubType();
                    weaponData.damage = playerInventoryWeaponScript.GetDamage();
                    inventory.Add(weaponData);
                    break;
                case "Amulet":
                    AmuletScript playerInventoryAmuletScript = playerInventoryItem.GetComponent<AmuletScript>();
                    AmuletData amuletData = new AmuletData();
                    amuletData.itemName = playerInventoryAmuletScript.itemName;
                    amuletData.inventoryPosition = playerInventoryAmuletScript.inventoryPosition;
                    amuletData.spellDamage = playerInventoryAmuletScript.spellDamage;
                    inventory.Add(amuletData);
                    break;
                case "Coat":
                    CoatScript playerInventoryCoatScript = playerInventoryItem.GetComponent<CoatScript>();
                    CoatData coatData = new CoatData();
                    coatData.itemName = playerInventoryCoatScript.itemName;
                    coatData.inventoryPosition = playerInventoryCoatScript.inventoryPosition;
                    coatData.armor = playerInventoryCoatScript.armorBonus;
                    coatData.health = playerInventoryCoatScript.healthBonus;
                    inventory.Add(coatData);
                    break;
                case "Gloves":
                    GlovesScript playerInventoryGlovesScript = playerInventoryItem.GetComponent<GlovesScript>();
                    GlovesData glovesData = new GlovesData();
                    glovesData.itemName = playerInventoryGlovesScript.itemName;
                    glovesData.inventoryPosition = playerInventoryGlovesScript.inventoryPosition;
                    glovesData.armor = playerInventoryGlovesScript.armorBonus;
                    glovesData.damage = playerInventoryGlovesScript.damageBonus;
                    inventory.Add(glovesData);
                    break;
                case "Pants":
                    PantsScript playerInventoryPantsScript = playerInventoryItem.GetComponent<PantsScript>();
                    PantsData pantsData = new PantsData();
                    pantsData.itemName = playerInventoryPantsScript.itemName;
                    pantsData.inventoryPosition = playerInventoryPantsScript.inventoryPosition;
                    pantsData.armor = playerInventoryPantsScript.armorBonus;
                    pantsData.pickupRadius = playerInventoryPantsScript.pickupRadius;
                    inventory.Add(pantsData);
                    break;
                case "Boots":
                    BootsScript playerInventoryBootsScript = playerInventoryItem.GetComponent<BootsScript>();
                    BootsData bootsData = new BootsData();
                    bootsData.itemName = playerInventoryBootsScript.itemName;
                    bootsData.inventoryPosition = playerInventoryBootsScript.inventoryPosition;
                    bootsData.armor = playerInventoryBootsScript.armorBonus;
                    bootsData.speed = playerInventoryBootsScript.speedBonus;
                    inventory.Add(bootsData);
                    break;
                case "Tome":
                    SkillTomeScript playerInventoryTomeScript = playerInventoryItem.GetComponent<SkillTomeScript>();
                    TomeData tomeData = new TomeData();
                    tomeData.itemName = playerInventoryItemScript.ItemName();
                    tomeData.skillName = playerInventoryTomeScript.skillName;
                    tomeData.inventoryPosition = playerInventoryTomeScript.inventoryPosition;
                    inventory.Add(tomeData);
                    break;
            }
        }
        // get player utility skills
        Transform playerUtilitySkills = playerScript.utilitySkills;
        utilitySkills = new string[5];
        for (int i = 0; i < playerUtilitySkills.childCount; i++)
        {
            GameObject playerSkill = playerUtilitySkills.GetChild(i).gameObject;
            Skill playerSkillScript = playerSkill.GetComponent<Skill>();
            int skillIndex = playerSkillScript.skillBarPosition - 4;
            if (utilitySkills[skillIndex] != null)
            {
                Debug.LogError($"there is already a skill in slot {skillIndex + 4}");
            }
            else
            {
                utilitySkills[skillIndex] = playerSkillScript.GetSkillName();
            }
        }
    }
}
