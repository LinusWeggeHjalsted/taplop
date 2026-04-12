using UnityEngine;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class LevelBuilderScript : MonoBehaviour
{
    public class PreParse
    {
        public string[] levelMetadata;
        public char[][] levelLayout;
        public List<string[]> enemyInfo;
        public List<string[]> decorationInfo;
        public List<string[]> itemInfo;
    }

    public class PreEnemy
    {
        public string enemyName;
        public string enemySprite;
        public int enemyColor;
        public bool usesWeapons;
        public int maxHealth;
        public int armor;
        public int speed;
        public int aggroRange;
        public string mainHandWeapon;
        public string mainHandName;
        public int mainHandDamage;
        public string offHandWeapon;
        public string offHandName;
        public int offHandDamage;
        public string amuletName;
        public int amuletSpellDamage;
        public string coatName;
        public int coatArmor;
        public int coatHealth;
        public string glovesName;
        public int glovesHealth;
        public int glovesDamage;
        public string pantsName;
        public int pantsHealth;
        public int pantsPickupRadius;
        public string bootsName;
        public int bootsHealth;
        public int bootsSpeed;
        public List<string> utilitySkills;
    }

    public class PreDecoration
    {
        public string decorationSprite;
        public int colorCode;
    }

    public class PreItem
    {
        public string itemName;
        public string itemType;
        public string weaponType;
        public int armor;
        public int health;
        public int damage;
        public int spellDamage;
        public int pickupRadius;
        public int speed;
    }

    public class ParsedLevel
    {
        public List<Vector3> tilePositions;
        public Vector3 endPosition;
        public Vector3 playerPosition;
        public Dictionary<Vector3, char> enemyPositions;
        public Dictionary<char, PreEnemy> preEnemies;
        public Dictionary<Vector3, char> decorationPositions;
        public Dictionary<char, PreDecoration> preDecorations;
        public Dictionary<Vector3, char> itemPositions;
        public Dictionary<char, PreItem> preItems;
    }
    
    public bool finishedBuilding = false;
    public GameObject missionLogic;
    public MissionLogicScript missionLogicScript;
    public GameObject level;
    public string levelName;
    public GameObject player;
    public GameObject enemies;
    public GameObject decorations;
    public GameObject drops;
    public GameObject traversableTiles;
    public GameObject tilePrefab;
    public GameObject enemyPrefab;
    public GameObject decorationPrefab;
    public GameObject groundItemsPrefab;

    public PreParse LoadLevelFile(string lvlName)
    {
        PreParse preParse = new PreParse();
        string filePath = "Levels/" + lvlName;
        TextAsset levelFile = Resources.Load<TextAsset>(filePath);
        if (levelFile == null)
        {
            Debug.LogError("No level file found at path " + filePath);
        }
        else
        {
            string[] fileLines = levelFile.text.Split('\n');
            string[] sectionHeaders = new string[] {
                "Metadata",
                "Layout",
                "Enemy Info",
                "Decoration Info",
                "Item Info"
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

            // metadata
            string[] metadataBlock = sectionBlocks[0];

            // layout
            int layoutLength = sectionLengths[1];
            string[] layoutBlock = sectionBlocks[1];
            char[][] layout = new char[layoutLength][];
            for (int i = 0; i < layoutLength; i++)
            {
                layout[i] = layoutBlock[i].ToCharArray();
            }

            // enemy info
            string[] enemyInfoBlock = sectionBlocks[2];
            List<string[]> enemyInfo = new List<string[]>();
            List<string> currentSubArray = new List<string>();
            foreach (string line in enemyInfoBlock)
            {
                if (line == "")
                {
                    enemyInfo.Add(currentSubArray.ToArray());
                    currentSubArray.Clear();
                }
                else
                {
                    currentSubArray.Add(line);
                }
            }
            if (currentSubArray.Count > 0)
            {
                enemyInfo.Add(currentSubArray.ToArray());
            }

            // decoration info
            string[] decorationInfoBlock = sectionBlocks[3];
            List<string[]> decorationInfo = new List<string[]>();
            currentSubArray = new List<string>();
            foreach (string line in decorationInfoBlock)
            {
                if (line == "")
                {
                    decorationInfo.Add(currentSubArray.ToArray());
                    currentSubArray.Clear();
                }
                else
                {
                    currentSubArray.Add(line);
                }
            }
            if (currentSubArray.Count > 0)
            {
                decorationInfo.Add(currentSubArray.ToArray());
            }

            // item info
            string[] itemInfoBlock = sectionBlocks[4];
            List<string[]> itemInfo = new List<string[]>();
            currentSubArray = new List<string>();
            foreach (string line in itemInfoBlock)
            {
                if (line == "")
                {
                    itemInfo.Add(currentSubArray.ToArray());
                    currentSubArray.Clear();
                }
                else
                {
                    currentSubArray.Add(line);
                }
            }
            if (currentSubArray.Count > 0)
            {
                itemInfo.Add(currentSubArray.ToArray());
            }

            preParse.levelMetadata = metadataBlock;
            preParse.levelLayout = layout;
            preParse.enemyInfo = enemyInfo;
            preParse.decorationInfo = decorationInfo;
            preParse.itemInfo = itemInfo;
        }   
        return preParse;
    }

    public ParsedLevel ParseLevel(PreParse preParse)
    {
        ParsedLevel parsedLevel = new ParsedLevel();
        parsedLevel.tilePositions = new List<Vector3>();
        parsedLevel.enemyPositions = new Dictionary<Vector3, char>();
        parsedLevel.preEnemies = new Dictionary<char, PreEnemy>();
        parsedLevel.decorationPositions = new Dictionary<Vector3, char>();
        parsedLevel.preDecorations = new Dictionary<char, PreDecoration>();
        parsedLevel.itemPositions = new Dictionary<Vector3, char>();
        parsedLevel.preItems = new Dictionary<char, PreItem>();
        // parse individual enemy information
        foreach (string[] enemyStrings in preParse.enemyInfo)
        {
            PreEnemy preEnemy = new PreEnemy();
            preEnemy.utilitySkills = new List<string>();
            if (enemyStrings[0].Length > 1)
            {
                Debug.LogError("bad enemy info, first line should be a single character");
                continue;
            }
            char enemyCode = enemyStrings[0][0];
            for (int i = 1; i < enemyStrings.Length; i++)
            {
                string currentLine = enemyStrings[i];
                if (currentLine.StartsWith("name "))
                {
                    string enemyName = currentLine.Substring("name ".Length);
                    preEnemy.enemyName = enemyName;
                }
                if (currentLine.StartsWith("usesWeapons "))
                {
                    string usesWeapons = currentLine.Substring("usesWeapons ".Length);
                    int usesWeaponsNumber;
                    if (Int32.TryParse(usesWeapons, out usesWeaponsNumber))
                    {
                        if (usesWeaponsNumber == 1)
                        {
                            preEnemy.usesWeapons = true;
                        }
                        else if (usesWeaponsNumber == 0)
                        {
                            preEnemy.usesWeapons = false;
                        }
                        else
                        {
                            Debug.LogError("usesWeapons is not 0 or 1");
                        }
                    }
                    else
                    {
                        Debug.LogError("usesWeapons is not 0 or 1");
                    }
                }
                if (currentLine.StartsWith("sprite "))
                {
                    string enemySprite = currentLine.Substring("sprite ".Length);
                    preEnemy.enemySprite = enemySprite;
                }
                else if (currentLine.StartsWith("maxHealth "))
                {
                    string enemyMaxHealth = currentLine.Substring("maxHealth ".Length);
                    int maxHealthNumber;
                    if (Int32.TryParse(enemyMaxHealth, out maxHealthNumber))
                    {
                        preEnemy.maxHealth = maxHealthNumber;
                    }
                    else
                    {
                        Debug.LogError("maxHealth is not a number");
                    }
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string enemyArmor = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(enemyArmor, out armorNumber))
                    {
                        preEnemy.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("armor is not a number");
                    }
                }
                else if (currentLine.StartsWith("speed "))
                {
                    string enemySpeed = currentLine.Substring("speed ".Length);
                    int speedNumber;
                    if (Int32.TryParse(enemySpeed, out speedNumber))
                    {
                        preEnemy.speed = speedNumber;
                    }
                    else
                    {
                        Debug.LogError("speed is not a number");
                    }
                }
                else if (currentLine.StartsWith("aggroRange "))
                {
                    string enemyAggroRange = currentLine.Substring("aggroRange ".Length);
                    int aggroRangeNumber;
                    if (Int32.TryParse(enemyAggroRange, out aggroRangeNumber))
                    {
                        preEnemy.aggroRange = aggroRangeNumber;
                    }
                    else
                    {
                        Debug.LogError("aggroRange is not a number");
                    }
                }
                else if (currentLine.StartsWith("mainHandWeapon "))
                {
                    string enemyMainHandWeapon = currentLine.Substring("mainHandWeapon ".Length);
                    preEnemy.mainHandWeapon = enemyMainHandWeapon;
                }
                else if (currentLine.StartsWith("mainHandName "))
                {
                    string enemyMainHandName = currentLine.Substring("mainHandName ".Length);
                    preEnemy.mainHandName = enemyMainHandName;
                }
                else if (currentLine.StartsWith("mainHandDamage "))
                {
                    string enemyMainHandDamage = currentLine.Substring("mainHandDamage ".Length);
                    int mainHandDamageNumber;
                    if (Int32.TryParse(enemyMainHandDamage, out mainHandDamageNumber))
                    {
                        preEnemy.mainHandDamage = mainHandDamageNumber;
                    }
                    else
                    {
                        Debug.LogError("mainHandDamage is not a number");
                    }
                }
                else if (currentLine.StartsWith("offHandWeapon "))
                {
                    string enemyOffHandWeapon = currentLine.Substring("offHandWeapon ".Length);
                    preEnemy.offHandWeapon = enemyOffHandWeapon;
                }
                else if (currentLine.StartsWith("offHandName "))
                {
                    string enemyOffHandName = currentLine.Substring("offHandName ".Length);
                    preEnemy.offHandName = enemyOffHandName;
                }
                else if (currentLine.StartsWith("offHandDamage "))
                {
                    string enemyOffHandDamage = currentLine.Substring("offHandDamage ".Length);
                    int offHandDamageNumber;
                    if (Int32.TryParse(enemyOffHandDamage, out offHandDamageNumber))
                    {
                        preEnemy.offHandDamage = offHandDamageNumber;
                    }
                    else
                    {
                        Debug.LogError("offHandDamage is not a number");
                    }
                }
                else if (currentLine.StartsWith("amuletName "))
                {
                    string amuletName = currentLine.Substring("amuletName ".Length);
                    preEnemy.amuletName = amuletName;
                }
                else if (currentLine.StartsWith("amuletSpellDamage "))
                {
                    string amuletSpellDamage = currentLine.Substring("amuletSpellDamage ".Length);
                    int amuletSpellDamageNumber;
                    if (Int32.TryParse(amuletSpellDamage, out amuletSpellDamageNumber))
                    {
                        preEnemy.amuletSpellDamage = amuletSpellDamageNumber;
                    }
                    else
                    {
                        Debug.LogError("amuletSpellDamage is not a number");
                    }
                }
                else if (currentLine.StartsWith("coatName "))
                {
                    string coatName = currentLine.Substring("coatName ".Length);
                    preEnemy.coatName = coatName;
                }
                else if (currentLine.StartsWith("coatArmor "))
                {
                    string coatArmor = currentLine.Substring("coatArmor ".Length);
                    int coatArmorNumber;
                    if (Int32.TryParse(coatArmor, out coatArmorNumber))
                    {
                        preEnemy.coatArmor = coatArmorNumber;
                    }
                    else
                    {
                        Debug.LogError("coatArmor is not a number");
                    }
                }
                else if (currentLine.StartsWith("coatHealth "))
                {
                    string coatHealth = currentLine.Substring("coatHealth ".Length);
                    int coatHealthNumber;
                    if (Int32.TryParse(coatHealth, out coatHealthNumber))
                    {
                        preEnemy.coatHealth = coatHealthNumber;
                    }
                    else
                    {
                        Debug.LogError("coatHealth is not a number");
                    }
                }
                else if (currentLine.StartsWith("glovesName "))
                {
                    string glovesName = currentLine.Substring("glovesName ".Length);
                    preEnemy.glovesName = glovesName;
                }
                else if (currentLine.StartsWith("glovesHealth "))
                {
                    string glovesHealth = currentLine.Substring("glovesHealth ".Length);
                    int glovesHealthNumber;
                    if (Int32.TryParse(glovesHealth, out glovesHealthNumber))
                    {
                        preEnemy.glovesHealth = glovesHealthNumber;
                    }
                    else
                    {
                        Debug.LogError("glovesHealth is not a number");
                    }
                }
                else if (currentLine.StartsWith("glovesDamage "))
                {
                    string glovesDamage = currentLine.Substring("glovesDamage ".Length);
                    int glovesDamageNumber;
                    if (Int32.TryParse(glovesDamage, out glovesDamageNumber))
                    {
                        preEnemy.glovesDamage = glovesDamageNumber;
                    }
                    else
                    {
                        Debug.LogError("glovesDamage is not a number");
                    }
                }
                else if (currentLine.StartsWith("pantsName "))
                {
                    string pantsName = currentLine.Substring("pantsName ".Length);
                    preEnemy.pantsName = pantsName;
                }
                else if (currentLine.StartsWith("pantsHealth "))
                {
                    string pantsHealth = currentLine.Substring("pantsHealth ".Length);
                    int pantsHealthNumber;
                    if (Int32.TryParse(pantsHealth, out pantsHealthNumber))
                    {
                        preEnemy.pantsHealth = pantsHealthNumber;
                    }
                    else
                    {
                        Debug.LogError("pantsHealth is not a number");
                    }
                }
                else if (currentLine.StartsWith("pantsPickupRadius "))
                {
                    string pantsPickupRadius = currentLine.Substring("pantsPickupRadius ".Length);
                    int pantsPickupRadiusNumber;
                    if (Int32.TryParse(pantsPickupRadius, out pantsPickupRadiusNumber))
                    {
                        preEnemy.pantsPickupRadius = pantsPickupRadiusNumber;
                    }
                    else
                    {
                        Debug.LogError("pantsPickupRadius is not a number");
                    }
                }
                else if (currentLine.StartsWith("bootsName "))
                {
                    string bootsName = currentLine.Substring("bootsName ".Length);
                    preEnemy.bootsName = bootsName;
                }
                else if (currentLine.StartsWith("bootsHealth "))
                {
                    string bootsHealth = currentLine.Substring("bootsHealth ".Length);
                    int bootsHealthNumber;
                    if (Int32.TryParse(bootsHealth, out bootsHealthNumber))
                    {
                        preEnemy.bootsHealth = bootsHealthNumber;
                    }
                    else
                    {
                        Debug.LogError("bootsHealth is not a number");
                    }
                }
                else if (currentLine.StartsWith("bootsSpeed "))
                {
                    string bootsSpeed = currentLine.Substring("bootsSpeed ".Length);
                    int bootsSpeedNumber;
                    if (Int32.TryParse(bootsSpeed, out bootsSpeedNumber))
                    {
                        preEnemy.bootsSpeed = bootsSpeedNumber;
                    }
                    else
                    {
                        Debug.LogError("bootsSpeed is not a number");
                    }
                }
                else if (currentLine.StartsWith("utilitySkill "))
                {
                    string utilitySkill = currentLine.Substring("utilitySkill ".Length);
                    preEnemy.utilitySkills.Add(utilitySkill);
                }
            }
            parsedLevel.preEnemies.Add(enemyCode, preEnemy);
        }
        // parse individual decoration information
        foreach (string[] decorationStrings in preParse.decorationInfo)
        {
            PreDecoration preDecoration = new PreDecoration();
            if (decorationStrings[0].Length > 1)
            {
                Debug.LogError("bad decoration info, first line should be a single character");
                continue;
            }
            char decorationCode = decorationStrings[0][0];
            for (int i = 1; i < decorationStrings.Length; i++)
            {
                string currentLine = decorationStrings[i];
                if (currentLine.StartsWith("sprite "))
                {
                    string decorationSprite = currentLine.Substring("sprite ".Length);
                    preDecoration.decorationSprite = decorationSprite;
                }
                else if (currentLine.StartsWith("colorCode "))
                {
                    string colorCode = currentLine.Substring("colorCode ".Length);
                    int colorCodeNumber;
                    if (Int32.TryParse(colorCode, out colorCodeNumber))
                    {
                        preDecoration.colorCode = colorCodeNumber;
                    }
                    else
                    {
                        Debug.LogError("colorCode is not a number");
                    }
                }
            }
            parsedLevel.preDecorations.Add(decorationCode, preDecoration);
        }
        // parse individual item information
        foreach (string[] itemStrings in preParse.itemInfo)
        {
            PreItem preItem = new PreItem();
            if (itemStrings[0].Length > 1)
            {
                Debug.LogError("bad item info, first line should be a single character");
                continue;
            }
            char itemCode = itemStrings[0][0];
            for (int i = 1; i < itemStrings.Length; i++)
            {
                string currentLine = itemStrings[i];
                if (currentLine.StartsWith("name "))
                {
                    string itemName = currentLine.Substring("name ".Length);
                    preItem.itemName = itemName;
                }
                else if (currentLine.StartsWith("type "))
                {
                    string itemType = currentLine.Substring("type ".Length);
                    preItem.itemType = itemType;
                }
                else if (currentLine.StartsWith("weaponType "))
                {
                    string weaponType = currentLine.Substring("weaponType ".Length);
                    preItem.weaponType = weaponType;
                }
                else if (currentLine.StartsWith("armor "))
                {
                    string armor = currentLine.Substring("armor ".Length);
                    int armorNumber;
                    if (Int32.TryParse(armor, out armorNumber))
                    {
                        preItem.armor = armorNumber;
                    }
                    else
                    {
                        Debug.LogError("armor is not a number");
                    }
                }
                else if (currentLine.StartsWith("damage "))
                {
                    string damage = currentLine.Substring("damage ".Length);
                    int damageNumber;
                    if (Int32.TryParse(damage, out damageNumber))
                    {
                        preItem.damage = damageNumber;
                    }
                    else
                    {
                        Debug.LogError("damage is not a number");
                    }
                }
                else if (currentLine.StartsWith("spellDamage "))
                {
                    string spellDamage = currentLine.Substring("spellDamage ".Length);
                    int spellDamageNumber;
                    if (Int32.TryParse(spellDamage, out spellDamageNumber))
                    {
                        preItem.spellDamage = spellDamageNumber;
                    }
                    else
                    {
                        Debug.LogError("spellDamage is not a number");
                    }
                }
                else if (currentLine.StartsWith("health "))
                {
                    string health = currentLine.Substring("health ".Length);
                    int healthNumber;
                    if (Int32.TryParse(health, out healthNumber))
                    {
                        preItem.health = healthNumber;
                    }
                    else
                    {
                        Debug.LogError("health is not a number");
                    }
                }
                else if (currentLine.StartsWith("speed "))
                {
                    string speed = currentLine.Substring("speed ".Length);
                    int speedNumber;
                    if (Int32.TryParse(speed, out speedNumber))
                    {
                        preItem.speed = speedNumber;
                    }
                    else
                    {
                        Debug.LogError("speed is not a number");
                    }
                }
            }
            parsedLevel.preItems.Add(itemCode, preItem);
        }
        // find positions of things
        for (int i = 0; i < preParse.levelLayout.Length; i++)
        {
            for (int j = 0; j < preParse.levelLayout[i].Length; j++)
            {
                // flip y axis
                Vector3 position = new Vector3(j, preParse.levelLayout.Length - i, 0);
                char tileCode = preParse.levelLayout[i][j];
                if (tileCode != ' ')
                {
                    parsedLevel.tilePositions.Add(position);
                    if (tileCode == '.')
                    {
                        continue;
                    }
                    if (tileCode == '!')
                    {
                        parsedLevel.playerPosition = position;
                        continue;
                    }
                    if (tileCode == '=')
                    {
                        parsedLevel.endPosition = position;
                        continue;
                    }
                    else
                    {
                        if (parsedLevel.preEnemies.ContainsKey(tileCode))
                        {
                            parsedLevel.enemyPositions.Add(position, tileCode);
                        }
                        if (parsedLevel.preDecorations.ContainsKey(tileCode))
                        {
                            parsedLevel.decorationPositions.Add(position, tileCode);
                            parsedLevel.tilePositions.Remove(position);
                        }
                        if (parsedLevel.preItems.ContainsKey(tileCode))
                        {
                            parsedLevel.itemPositions.Add(position, tileCode);
                        }
                    }
                }
            }
        }
        return parsedLevel;
    }

    public void BuildLevel(ParsedLevel parsedLevel)
    {
        player.transform.position = parsedLevel.playerPosition;
        EntityScript playerScript = player.GetComponent<EntityScript>();
        playerScript.spriteRenderer.sortingOrder = 10 * (int)-parsedLevel.playerPosition.y;
        playerScript.mainHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-parsedLevel.playerPosition.y + 1;
        playerScript.offHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-parsedLevel.playerPosition.y + 1;
        CameraControllerScript.Instance.MoveToPlayer();
        // build tiles
        for (int i = 0; i < parsedLevel.tilePositions.Count; i++)
        {
            GameObject newTile = Instantiate(tilePrefab, traversableTiles.transform);
            newTile.transform.position = parsedLevel.tilePositions[i];
            TileScript tileScript = newTile.GetComponent<TileScript>();
            if (parsedLevel.tilePositions[i] == parsedLevel.playerPosition)
            {
                tileScript.isOccupied = true;
            }
            if (parsedLevel.enemyPositions.ContainsKey(parsedLevel.tilePositions[i]))
            {
                newTile.GetComponent<TileScript>().isOccupied = true;
            }
            if (parsedLevel.tilePositions[i] == parsedLevel.endPosition)
            {
                tileScript.IsEnd = true;
            }
            SpriteRenderer tileRenderer = newTile.GetComponent<SpriteRenderer>();
            switch ((newTile.transform.position.x + newTile.transform.position.y) % 2)
            {
                case 0:
                    tileRenderer.color = MissionLogicScript.Instance.missionColors[1];
                    break;
                case 1:
                    tileRenderer.color = MissionLogicScript.Instance.missionColors[3];
                    break;
            }
        }
        // build enemies
        foreach (Vector3 enemyPosition in parsedLevel.enemyPositions.Keys)
        {
            char enemyCode = parsedLevel.enemyPositions[enemyPosition];
            if (!parsedLevel.preEnemies.ContainsKey(enemyCode))
            {
                Debug.LogError("no enemy info for enemy code " + enemyCode.ToString());
                continue;
            }
            PreEnemy preEnemy = parsedLevel.preEnemies[enemyCode];
            GameObject newEnemy = Instantiate(enemyPrefab, enemies.transform);
            newEnemy.transform.position = enemyPosition;
            newEnemy.name = preEnemy.enemyName;
            EntityScript newEnemyScript = newEnemy.GetComponent<EntityScript>();
            newEnemyScript.spriteRenderer.sortingOrder = 10 * (int)-enemyPosition.y;
            if (preEnemy.usesWeapons)
            {
                newEnemyScript.mainHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-enemyPosition.y + 1;
                newEnemyScript.offHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-enemyPosition.y + 1;
                newEnemyScript.mainHandWeaponSpriteRenderer.enabled = true;
                newEnemyScript.offHandWeaponSpriteRenderer.enabled = true;
            }
            if (preEnemy.enemySprite != null)
            {
                newEnemyScript.SpriteSheet = Resources.LoadAll<Sprite>("Enemies/" + preEnemy.enemySprite);
            }
            newEnemyScript.MaxHealth = preEnemy.maxHealth;
            newEnemyScript.Armor = preEnemy.armor;
            newEnemyScript.Speed = preEnemy.speed;
            newEnemyScript.aggroRange = preEnemy.aggroRange;
            Transform enemyGear = newEnemy.transform.Find("Gear");
            Transform enemyMainHand = enemyGear.Find("Main Hand");
            Transform enemyOffHand = enemyGear.Find("Off Hand");
            Transform enemyNeck = enemyGear.Find("Neck");
            Transform enemyBody = enemyGear.Find("Body");
            Transform enemyHands = enemyGear.Find("Hands");
            Transform enemyLegs = enemyGear.Find("Legs");
            Transform enemyFeet = enemyGear.Find("Feet");
            Transform enemyUtilitySkills = newEnemy.transform.Find("Utility Skills");
            newEnemyScript.utilitySkillSlots = 5; // to-do - think about this
            GameObject mainHandWeaponPrefab = Resources.Load<GameObject>("Prefabs/Items/" + preEnemy.mainHandWeapon);
            if (mainHandWeaponPrefab != null)
            {
                GameObject enemyMainHandWeapon = Instantiate(mainHandWeaponPrefab, enemyMainHand);
                WeaponScript enemyMainHandWeaponScript = enemyMainHandWeapon.GetComponent<WeaponScript>();
                enemyMainHandWeaponScript.SetItemName(preEnemy.mainHandName);
                enemyMainHandWeaponScript.SetDamage(preEnemy.mainHandDamage);
            }
            GameObject offHandWeaponPrefab = Resources.Load<GameObject>("Prefabs/Items/" + preEnemy.offHandWeapon);
            if (offHandWeaponPrefab != null)
            {
                GameObject enemyOffHandWeapon = Instantiate(offHandWeaponPrefab, enemyOffHand);
                WeaponScript enemyOffHandWeaponScript = enemyOffHandWeapon.GetComponent<WeaponScript>();
                enemyOffHandWeaponScript.SetItemName(preEnemy.offHandName);
                enemyOffHandWeaponScript.SetDamage(preEnemy.offHandDamage);
            }
            if (preEnemy.amuletName != null)
            {
                GameObject amuletPrefab = Resources.Load<GameObject>("Prefabs/Items/Amulet");
                GameObject enemyAmulet = Instantiate(amuletPrefab, enemyNeck);
                AmuletScript enemyAmuletScript = enemyAmulet.GetComponent<AmuletScript>();
                enemyAmuletScript.itemName = preEnemy.amuletName;
                enemyAmuletScript.spellDamage = preEnemy.amuletSpellDamage;
            }
            if (preEnemy.coatName != null)
            {
                GameObject coatPrefab = Resources.Load<GameObject>("Prefabs/Items/Coat");
                GameObject enemyCoat = Instantiate(coatPrefab, enemyBody);
                CoatScript enemyCoatScript = enemyCoat.GetComponent<CoatScript>();
                enemyCoatScript.itemName = preEnemy.coatName;
                enemyCoatScript.armorBonus = preEnemy.coatArmor;
                enemyCoatScript.healthBonus = preEnemy.coatHealth;
            }
            if (preEnemy.glovesName != null)
            {
                GameObject glovesPrefab = Resources.Load<GameObject>("Prefabs/Items/Gloves");
                GameObject enemyGloves = Instantiate(glovesPrefab, enemyHands);
                GlovesScript enemyGlovesScript = enemyGloves.GetComponent<GlovesScript>();
                enemyGlovesScript.itemName = preEnemy.glovesName;
                enemyGlovesScript.healthBonus = preEnemy.glovesHealth;
                enemyGlovesScript.damageBonus = preEnemy.glovesDamage;
            }
            if (preEnemy.pantsName != null)
            {
                GameObject pantsPrefab = Resources.Load<GameObject>("Prefabs/Items/Pants");
                GameObject enemyPants = Instantiate(pantsPrefab, enemyLegs);
                PantsScript enemyPantsScript = enemyPants.GetComponent<PantsScript>();
                enemyPantsScript.itemName = preEnemy.pantsName;
                enemyPantsScript.healthBonus = preEnemy.pantsHealth;
                enemyPantsScript.pickupRadius = preEnemy.pantsPickupRadius;
            }
            if (preEnemy.bootsName != null)
            {
                GameObject bootsPrefab = Resources.Load<GameObject>("Prefabs/Items/Boots");
                GameObject enemyBoots = Instantiate(bootsPrefab, enemyFeet);
                BootsScript enemyBootsScript = enemyBoots.GetComponent<BootsScript>();
                enemyBootsScript.itemName = preEnemy.bootsName;
                enemyBootsScript.healthBonus = preEnemy.bootsHealth;
                enemyBootsScript.speedBonus = preEnemy.bootsSpeed;
            }
            for (int i = 0; i < preEnemy.utilitySkills.Count; i++)
            {
                string utilitySkill = preEnemy.utilitySkills[i];
                GameObject utilitySkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/" + utilitySkill);
                if (utilitySkillPrefab != null)
                {
                    GameObject skillObject = Instantiate(utilitySkillPrefab, enemyUtilitySkills);
                    SkillScript skillScript = skillObject.GetComponent<SkillScript>();
                    skillScript.skillBarPosition = i + 4;
                }
                else
                {
                    Debug.LogError($"utility skill {utilitySkill} not found");
                }
            }
        }
        // build decorations
        foreach (Vector3 decorationPosition in parsedLevel.decorationPositions.Keys)
        {
            char decorationCode = parsedLevel.decorationPositions[decorationPosition];
            if (!parsedLevel.preDecorations.ContainsKey(decorationCode))
            {
                Debug.LogError($"no decoration info for decoration code {decorationCode}");
                continue;
            }
            PreDecoration preDecoration = parsedLevel.preDecorations[decorationCode];
            GameObject newDecoration = Instantiate(decorationPrefab, decorations.transform);
            newDecoration.transform.position = decorationPosition;
            SpriteRenderer decorationRenderer = newDecoration.GetComponent<SpriteRenderer>();
            decorationRenderer.sortingOrder = 10 * (int)-decorationPosition.y;
            decorationRenderer.color = MissionLogicScript.Instance.missionColors[preDecoration.colorCode];
            DecorationScript newDecorationScript = newDecoration.GetComponent<DecorationScript>();
            if (preDecoration.decorationSprite != null)
            {
                Sprite[] decorationSpriteSheet = Resources.LoadAll<Sprite>("Decorations/" + preDecoration.decorationSprite);
                if (decorationSpriteSheet == null)
                {
                    Debug.LogError($"no decoration sprite found called {preDecoration.decorationSprite}");
                }
                else
                {
                    newDecorationScript.SpriteSheet = decorationSpriteSheet;
                }
            }
        }
        // build items
        foreach (Vector3 itemPosition in parsedLevel.itemPositions.Keys)
        {
            char itemCode = parsedLevel.itemPositions[itemPosition];
            if (!parsedLevel.preItems.ContainsKey(itemCode))
            {
                Debug.LogError("no item info for item code " + itemCode.ToString());
                continue;
            }
            PreItem preItem = parsedLevel.preItems[itemCode];

            GameObject newGroundItems = Instantiate(groundItemsPrefab, drops.transform);
            newGroundItems.transform.position = itemPosition;
            SpriteRenderer groundItemsRenderer = newGroundItems.GetComponent<SpriteRenderer>();
            groundItemsRenderer.sortingOrder = 10 * (int)-itemPosition.y;
            switch (preItem.itemType)
            {
                case "Weapon":
                    GameObject weaponPrefab = Resources.Load<GameObject>("Prefabs/Items/" + preItem.weaponType);
                    if (weaponPrefab != null)
                    {
                        GameObject newWeapon = Instantiate(weaponPrefab, newGroundItems.transform);
                        WeaponScript weaponScript = newWeapon.GetComponent<WeaponScript>();
                        weaponScript.SetItemName(preItem.itemName);
                        weaponScript.SetDamage(preItem.damage);
                    }
                    else
                    {
                        Debug.LogError("unrecognized weapon type");
                    }
                    break;
                case "Amulet":
                    GameObject amuletPrefab = Resources.Load<GameObject>("Prefabs/Items/Amulet");
                    GameObject newAmulet = Instantiate(amuletPrefab, newGroundItems.transform);
                    AmuletScript amuletScript = newAmulet.GetComponent<AmuletScript>();
                    amuletScript.itemName = preItem.itemName;
                    amuletScript.spellDamage = preItem.spellDamage;
                    break;
                case "Coat":
                    GameObject coatPrefab = Resources.Load<GameObject>("Prefabs/Items/Coat");
                    GameObject newCoat = Instantiate(coatPrefab, newGroundItems.transform);
                    CoatScript coatScript = newCoat.GetComponent<CoatScript>();
                    coatScript.itemName = preItem.itemName;
                    coatScript.armorBonus = preItem.armor;
                    coatScript.healthBonus = preItem.health;
                    break;
                case "Gloves":
                    GameObject glovesPrefab = Resources.Load<GameObject>("Prefabs/Items/Gloves");
                    GameObject newGloves = Instantiate(glovesPrefab, newGroundItems.transform);
                    GlovesScript glovesScript = newGloves.GetComponent<GlovesScript>();
                    glovesScript.itemName = preItem.itemName;
                    glovesScript.healthBonus = preItem.health;
                    glovesScript.damageBonus = preItem.damage;
                    break;
                case "Pants":
                    GameObject pantsPrefab = Resources.Load<GameObject>("Prefabs/Items/Pants");
                    GameObject newPants = Instantiate(pantsPrefab, newGroundItems.transform);
                    PantsScript pantsScript = newPants.GetComponent<PantsScript>();
                    pantsScript.itemName = preItem.itemName;
                    pantsScript.healthBonus = preItem.health;
                    pantsScript.pickupRadius = preItem.pickupRadius;
                    break;
                case "Boots":
                    GameObject bootsPrefab = Resources.Load<GameObject>("Prefabs/Items/Boots");
                    GameObject newBoots = Instantiate(bootsPrefab, newGroundItems.transform);
                    BootsScript bootsScript = newBoots.GetComponent<BootsScript>();
                    bootsScript.itemName = preItem.itemName;
                    bootsScript.healthBonus = preItem.health;
                    bootsScript.speedBonus = preItem.speed;
                    break;
            }
        }
    }

    void Awake()
    {
        tilePrefab = Resources.Load<GameObject>("Prefabs/Tile");
        enemyPrefab = Resources.Load<GameObject>("Prefabs/Enemy");
        decorationPrefab = Resources.Load<GameObject>("Prefabs/Decoration");
        groundItemsPrefab = Resources.Load<GameObject>("Prefabs/Ground Items");
    }

    void Start()
    {
        missionLogic = MissionLogicScript.Instance.gameObject;
        missionLogicScript = MissionLogicScript.Instance;
        levelName = missionLogicScript.currentLevelName;
        if (LevelScript.Instance != null)
        {
            LevelScript.Instance.CacheReferences();
            player = LevelScript.Instance.player;
            enemies = LevelScript.Instance.enemies;
            decorations = LevelScript.Instance.decorations;
            drops = LevelScript.Instance.drops;
            traversableTiles = LevelScript.Instance.traversableTiles;
            LevelScript.Instance.mainCamera.GetComponent<Camera>().backgroundColor = MissionLogicScript.Instance.missionColors[2];
        }
        BuildLevel(ParseLevel(LoadLevelFile(levelName)));
        StartCoroutine(PlayerDataScript.Instance.BuildPlayerFromData(player));
        finishedBuilding = true;
    }
}
