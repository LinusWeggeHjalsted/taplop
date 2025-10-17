using UnityEngine;
using System;
using System.Collections.Generic;

public class PlayerDataScript : MonoBehaviour
{
    public static PlayerDataScript Instance { get; private set;}

    public abstract class InventoryItemData
    {
        public string itemName;
    }

    public class WeaponData : InventoryItemData
    {
        public string weaponType;
        public int damage;
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

    public class BootsData : InventoryItemData
    {
        public int armor;
        public int speed;
    }

    public string playerName;
    
    // info
    public int turns;
    public int deaths;
    public int gems;
    public int utilitySkillSlots;
    public List<string> unlockedSkills = new List<string>();
    // to-do - hubs

    // gear
    public WeaponData mainHandWeapon;
    public WeaponData offHandWeapon;
    public CoatData coat;
    public GlovesData gloves;
    public BootsData boots;

    // inventory
    public List<InventoryItemData> inventory = new List<InventoryItemData>();

    // utility skill names
    public List<string> utilitySkills = new List<string>();

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

    public void LoadPlayerData(string savePath)
    {
        TextAsset playerSaveFile = Resources.Load<TextAsset>("New Player");
        if (playerSaveFile == null)
        {
            Debug.LogError("No save file found at path " + savePath);
        }
        else
        {
            string[] fileLines = playerSaveFile.text.Split('\n');
            int sectionCount = 9;
            string[] sectionHeaders = new string[] {
                "Info",
                "Unlocked Skills", 
                "Main Hand Weapon",
                "Off Hand Weapon",
                "Coat",
                "Gloves",
                "Boots",
                "Inventory",
                "Utility Skills"
            };
            int[] sectionIndices = new int[sectionCount];
            for (int i = 0; i < sectionCount; i++)
            {
                int sectionIndex = Array.IndexOf(fileLines, sectionHeaders[i]);
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
            }
            string[][] sectionBlocks = new string[sectionCount][];
            for (int i = 0; i < sectionCount; i++)
            {
                string[] sectionBlock = new string[sectionLengths[i]];
                Array.Copy(fileLines, sectionIndices[i], sectionBlock, 0, sectionLengths[i]);
                sectionBlocks[i] = sectionBlock;
            }
            
            // parse info
            string[] infoBlock = sectionBlocks[0];
            for (int i = 0; i < infoBlock.Length; i++)
            {
                string currentLine = infoBlock[i];
                if (currentLine.StartsWith("playerName "))
                {
                    playerName = currentLine.Substring("playerName ".Length);
                }
                else if (currentLine.StartsWith("turns "))
                {
                    string turnsString = currentLine.Substring("turns ".Length);
                    int turnsNumber;
                    if (Int32.TryParse(turnsString, out turnsNumber))
                    {
                        turns = turnsNumber;
                    }
                    else
                    {
                        Debug.LogError("turns is not a number");
                    }
                }
                else if (currentLine.StartsWith("deaths "))
                {
                    string deathsString = currentLine.Substring("deaths ".Length);
                    int deathsNumber;
                    if (Int32.TryParse(deathsString, out deathsNumber))
                    {
                        deaths = deathsNumber;
                    }
                    else
                    {
                        Debug.LogError("deaths is not a number");
                    }
                }
                else if (currentLine.StartsWith("gems "))
                {
                    string gemsString = currentLine.Substring("gems ".Length);
                    int gemsNumber;
                    if (Int32.TryParse(gemsString, out gemsNumber))
                    {
                        gems = gemsNumber;
                    }
                    else
                    {
                        Debug.LogError("gems is not a number");
                    }
                }
                else if (currentLine.StartsWith("utilitySkillSlots "))
                {
                    string utilitySkillSlotsString = currentLine.Substring("utilitySkillSlots ".Length);
                    int utilitySkillSlotsNumber;
                    if (Int32.TryParse(utilitySkillSlotsString, out utilitySkillSlotsNumber))
                    {
                        utilitySkillSlots = utilitySkillSlotsNumber;
                    }
                    else
                    {
                        Debug.LogError("utilitySkillSlots is not a number");
                    }
                }
            }
            // parse unlocked skills
            string[] unlockedSkillsBlock = sectionBlocks[1];
            unlockedSkills = new List<string>();
            for (int i = 0; i < unlockedSkillsBlock.Length; i++)
            {
                string skillName = unlockedSkillsBlock[i];
                unlockedSkills.Add(skillName);
            }
            // parse main hand weapon
            string[] mainHandWeaponBlock = sectionBlocks[2];
            mainHandWeapon = new WeaponData();
            for (int i = 0; i < mainHandWeaponBlock.Length; i++)
            {
                string currentLine = mainHandWeaponBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    mainHandWeapon.itemName = currentLine.Substring("itemName ".Length);
                }
                else if (currentLine.StartsWith("weaponType "))
                {
                    mainHandWeapon.weaponType = currentLine.Substring("weaponType ".Length);
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damageString = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damageString, out damageNumber))
                    {
                        mainHandWeapon.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("main hand damage is not a number");
                    }
                }
            }
            // parse off hand weapon
            string[] offHandWeaponBlock = sectionBlocks[3];
            offHandWeapon = new WeaponData();
            for (int i = 0; i < offHandWeaponBlock.Length; i++)
            {
                string currentLine = offHandWeaponBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    offHandWeapon.itemName = currentLine.Substring("itemName ".Length);
                }
                else if (currentLine.StartsWith("weaponType "))
                {
                    offHandWeapon.weaponType = currentLine.Substring("weaponType ".Length);
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damageString = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damageString, out damageNumber))
                    {
                        offHandWeapon.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("off hand damage is not a number");
                    }
                }
            }
            // parse coat
            string[] coatBlock = sectionBlocks[4];
            coat = new CoatData();
            for (int i = 0; i < coatBlock.Length; i++)
            {
                string currentLine = coatBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    coat.itemName = currentLine.Substring("itemName ".Length);
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        coat.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("coat armor is not a number");
                    }
                }
                else if (currentLine.StartsWith("health "))
                {
                    string healthString = currentLine.Substring("health ".Length);
                    int healthNumber;
                    if (Int32.TryParse(healthString, out healthNumber))
                    {
                        coat.health = healthNumber;
                    }
                    else
                    {
                        Debug.LogError("coat health is not a number");
                    }
                }
            }
            // parse gloves
            string[] glovesBlock = sectionBlocks[5];
            gloves = new GlovesData();
            for (int i = 0; i < glovesBlock.Length; i++)
            {
                string currentLine = glovesBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    gloves.itemName = currentLine.Substring("itemName ".Length);
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        gloves.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("gloves armor is not a number");
                    }
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damageString = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damageString, out damageNumber))
                    {
                        gloves.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("gloves damage is not a number");
                    }
                }
            }
            // parse boots
            string[] bootsBlock = sectionBlocks[6];
            boots = new BootsData();
            for (int i = 0; i < bootsBlock.Length; i++)
            {
                string currentLine = bootsBlock[i];
                if (currentLine.StartsWith("itemName "))
                {
                    boots.itemName = currentLine.Substring("itemName ".Length);
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armorString = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armorString, out armorNumber))
                    {
                        boots.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("boots armor is not a number");
                    }
                }
                else if (currentLine.StartsWith("speed "))
                {
                    string speedString = currentLine.Substring("speed ".Length);
                    int speedNumber;
                    if (Int32.TryParse(speedString, out speedNumber))
                    {
                        boots.speed = speedNumber;
                    }
                    else
                    {
                        Debug.LogError("boots speed is not a number");
                    }
                }
            }
            // to-do: parse inventory
            // parse utility skills
            string[] utilitySkillsBlock = sectionBlocks[8];
            utilitySkills = new List<string>();
            for (int i = 0; i < utilitySkillsBlock.Length; i++)
            {
                utilitySkills.Add(utilitySkillsBlock[i]);
            }
        }
    }

    public void SavePlayerData(string savePath)
    {

    }

    public void BuildPlayerFromData(GameObject player)
    {

    }
    
    public void BuildDataFromPlayer(GameObject player)
    {
        EntityScript playerScript = player.GetComponent<EntityScript>();
        
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
            mainHandWeapon = null;
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
            offHandWeapon = null;
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
            coat = null;
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
            gloves = null;
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
            boots = null;
        }

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
                    weaponData.weaponType = playerInventoryWeaponScript.ItemSubType();
                    weaponData.damage = playerInventoryWeaponScript.GetDamage();
                    inventory.Add(weaponData);
                    break;
                case "Coat":
                    CoatScript playerInventoryCoatScript = playerInventoryItem.GetComponent<CoatScript>();
                    CoatData coatData = new CoatData();
                    coatData.itemName = playerInventoryCoatScript.itemName;
                    coatData.armor = playerInventoryCoatScript.armorBonus;
                    coatData.health = playerInventoryCoatScript.healthBonus;
                    inventory.Add(coatData);
                    break;
                case "Gloves":
                    GlovesScript playerInventoryGlovesScript = playerInventoryItem.GetComponent<GlovesScript>();
                    GlovesData glovesData = new GlovesData();
                    glovesData.itemName = playerInventoryGlovesScript.itemName;
                    glovesData.armor = playerInventoryGlovesScript.armorBonus;
                    glovesData.damage = playerInventoryGlovesScript.damageBonus;
                    inventory.Add(glovesData);
                    break;
                case "Boots":
                    BootsScript playerInventoryBootsScript = playerInventoryItem.GetComponent<BootsScript>();
                    BootsData bootsData = new BootsData();
                    bootsData.itemName = playerInventoryBootsScript.itemName;
                    bootsData.armor = playerInventoryBootsScript.armorBonus;
                    bootsData.speed = playerInventoryBootsScript.speedBonus;
                    inventory.Add(bootsData);
                    break;
            }
        }

        Transform playerUtilitySkills = playerScript.utilitySkills;
        utilitySkills = new List<string>();
        for (int i = 0; i < playerUtilitySkills.childCount; i++)
        {
            GameObject playerSkill = playerUtilitySkills.GetChild(i).gameObject;
            Skill playerSkillScript = playerSkill.GetComponent<Skill>();
            utilitySkills.Add(playerSkillScript.GetSkillName());
        }
    }
}
