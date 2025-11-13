using UnityEngine;
using System;
using System.Collections;
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

    public bool finishedBuilding = false;

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
        LoadPlayerData("New Player");
    }

    public void LoadPlayerData(string savePath)
    {
        TextAsset playerSaveFile = Resources.Load<TextAsset>(savePath);
        if (playerSaveFile == null)
        {
            Debug.LogError("No save file found at path " + savePath);
        }
        else
        {
            string[] fileLines = playerSaveFile.text.Split('\n');
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
            // parse inventory
            string[] inventoryBlock = sectionBlocks[7];
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
            foreach (string[] itemBlock in inventoryItemBlocks)
            {
                // first line should define itemType
                string firstLine = itemBlock[0];
                if (firstLine.StartsWith("itemType "))
                {
                    string itemType = firstLine.Substring("itemType ".Length);
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
                                }
                                else if (currentLine.StartsWith("weaponType "))
                                {
                                    inventoryWeapon.weaponType = currentLine.Substring("weaponType ".Length);
                                }
                                else if (currentLine.StartsWith("damage "))
                                {
                                    string damageString = currentLine.Substring("damage ".Length);
                                    int damageNumber;
                                    if (Int32.TryParse(damageString, out damageNumber))
                                    {
                                        inventoryWeapon.damage = damageNumber;
                                    }
                                    else
                                    {
                                        Debug.LogError("inventory weapon damage is not a number");
                                    }
                                }
                            }
                            inventory.Add(inventoryWeapon);
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
                            }
                            inventory.Add(inventoryGloves);
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
                            }
                            inventory.Add(inventoryBoots);
                            break;
                    }
                }
                else
                {
                    Debug.LogError("item in inventory is not specifying its item type");
                }
            }
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
        // to-do
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
        Transform playerBody = playerScript.body;
        Transform playerHands = playerScript.hands;
        Transform playerFeet = playerScript.feet;
        Transform playerInventory = playerScript.inventory;
        Transform playerUtilitySkills = playerScript.utilitySkills;
        // clear out player
        void ClearChildren(Transform playerPart)
        {
            for (int i = playerPart.childCount - 1; i >= 0; i--)
            {
                GameObject partChild = playerPart.GetChild(i).gameObject;
                Destroy(partChild);
            }
        }
        ClearChildren(playerMainHand);
        ClearChildren(playerOffHand);
        ClearChildren(playerBody);
        ClearChildren(playerHands);
        ClearChildren(playerFeet);
        ClearChildren(playerInventory);
        ClearChildren(playerUtilitySkills);
        // update player info
        playerScript.utilitySkillSlots = utilitySkillSlots;
        // create player gear
        if (mainHandWeapon != null)
        {
            GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/" + mainHandWeapon.weaponType);
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
        if (offHandWeapon != null)
        {
            GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/" + offHandWeapon.weaponType);
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
        if (coat != null)
        {
            GameObject coatPrefab = Resources.Load<GameObject>("Prefabs/Coat");
            GameObject newCoat = Instantiate(coatPrefab, playerBody);
            CoatScript coatScript = newCoat.GetComponent<CoatScript>();
            coatScript.itemName = coat.itemName;
            coatScript.armorBonus = coat.armor;
            coatScript.healthBonus = coat.health;
        }
        if (gloves != null)
        {
            GameObject glovesPrefab = Resources.Load<GameObject>("Prefabs/Gloves");
            GameObject newGloves = Instantiate(glovesPrefab, playerHands);
            GlovesScript glovesScript = newGloves.GetComponent<GlovesScript>();
            glovesScript.itemName = gloves.itemName;
            glovesScript.armorBonus = gloves.armor;
            glovesScript.damageBonus = gloves.damage;
        }
        if (boots != null)
        {
            GameObject bootsPrefab = Resources.Load<GameObject>("Prefabs/Boots");
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
                GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/" + inventoryWeapon.weaponType);
                GameObject newWeapon = Instantiate(weaponPrefab, playerInventory);
                WeaponScript weaponScript = newWeapon.GetComponent<WeaponScript>();
                weaponScript.SetItemName(inventoryWeapon.itemName);
                weaponScript.SetDamage(inventoryWeapon.damage);
            }
            else if (inventoryItem is CoatData)
            {
                CoatData inventoryCoat = (CoatData)inventoryItem;
                GameObject coatPrefab = Resources.Load<GameObject>("Prefabs/Coat");
                GameObject newCoat = Instantiate(coatPrefab, playerInventory);
                CoatScript coatScript = newCoat.GetComponent<CoatScript>();
                coatScript.itemName = inventoryCoat.itemName;
                coatScript.armorBonus = inventoryCoat.armor;
                coatScript.healthBonus = inventoryCoat.health;
            }
            else if (inventoryItem is GlovesData)
            {
                GlovesData inventoryGloves = (GlovesData)inventoryItem;
                GameObject glovesPrefab = Resources.Load<GameObject>("Prefabs/Gloves");
                GameObject newGloves = Instantiate(glovesPrefab, playerInventory);
                GlovesScript glovesScript = newGloves.GetComponent<GlovesScript>();
                glovesScript.itemName = inventoryGloves.itemName;
                glovesScript.armorBonus = inventoryGloves.armor;
                glovesScript.damageBonus = inventoryGloves.damage;
            }
            else if (inventoryItem is BootsData)
            {
                BootsData inventoryBoots = (BootsData)inventoryItem;
                GameObject bootsPrefab = Resources.Load<GameObject>("Prefabs/Boots");
                GameObject newBoots = Instantiate(bootsPrefab, playerInventory);
                BootsScript bootsScript = newBoots.GetComponent<BootsScript>();
                bootsScript.itemName = inventoryBoots.itemName;
                bootsScript.armorBonus = inventoryBoots.armor;
                bootsScript.speedBonus = inventoryBoots.speed;
            }
        }
        // create player utility skills
        foreach (string skillName in utilitySkills)
        {
            if (unlockedSkills.Contains(skillName))
            {
                GameObject skillPrefab = Resources.Load<GameObject>("Prefabs/" + skillName);
                GameObject newSkill = Instantiate(skillPrefab, playerUtilitySkills);
            }
            else
            {
                Debug.LogError("player has not unlocked the skill " + skillName);
            }
        }
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
        // get player utility skills
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
