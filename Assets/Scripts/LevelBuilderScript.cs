using UnityEngine;
using System;
using System.Collections.Generic;
using System.Linq;

public class LevelBuilderScript : MonoBehaviour
{
    public class PreParse
    {
        public string levelDescription;
        public char[][] levelLayout;
        public List<string[]> enemyInfo;
    }

    public class PreEnemy
    {
        public string enemyName;
        public int maxHealth;
        public int armor;
        public int speed;
        public int aggroRange;
        public int unlockedSkills;
        public string mainHandWeapon;
        public int mainHandDamage;
        public string offHandWeapon;
        public int offHandDamage;
    }

    public class ParsedLevel
    {
        public List<Vector3> tilePositions;
        public Vector3 playerPosition;
        public Dictionary<Vector3, char> enemyPositions;
        public Dictionary<char, PreEnemy> preEnemies;
    }
    
    public bool finishedBuilding = false;
    public GameObject missionLogic;
    public MissionLogicScript missionLogicScript;
    public GameObject level;
    public LevelScript levelScript;
    public string levelName;
    public GameObject player;
    public GameObject enemies;
    public GameObject traversableTiles;
    public GameObject tilePrefab;
    public GameObject enemyPrefab;

    public PreParse LoadLevelFile(string lvlName)
    {
        PreParse preParse = new PreParse();
        string filePath = "Levels/" + lvlName;
        Debug.Log("Loading level file " + filePath);
        TextAsset levelFile = Resources.Load<TextAsset>(filePath);
        if (levelFile == null)
        {
            Debug.LogError("No file with name " + filePath + " found in Levels");
        }
        else
        {
            string[] fileLines = levelFile.text.Split('\n');
            int descriptionIndex = Array.IndexOf(fileLines, "Description") + 1;
            Debug.Log("descriptionIndex is " + descriptionIndex.ToString());
            int layoutIndex = Array.IndexOf(fileLines, "Layout") + 1;
            Debug.Log("layoutIndex is " + layoutIndex.ToString());
            int enemyInfoIndex = Array.IndexOf(fileLines, "Enemy Info") + 1;
            Debug.Log("enemyInfoIndex is " + enemyInfoIndex.ToString());
            // to-do: handle bad files

            int descriptionLength = layoutIndex - descriptionIndex - 2;
            int layoutLength = enemyInfoIndex - layoutIndex - 2;
            Debug.Log("layoutLength is " + layoutLength.ToString());
            int enemyInfoLength = fileLines.Length - enemyInfoIndex - 2;

            string description = fileLines[descriptionIndex];

            string[] layoutBlock = new string[layoutLength];
            Array.Copy(fileLines, layoutIndex, layoutBlock, 0, layoutLength);
            char[][] layout = new char[layoutLength][];
            for (int i = 0; i < layoutLength; i++)
            {
                layout[i] = layoutBlock[i].ToCharArray();
            }

            string[] enemyInfoBlock = new string[enemyInfoLength];
            Array.Copy(fileLines, enemyInfoIndex, enemyInfoBlock, 0, enemyInfoLength);
            // to-do - chop up enemy info, slice by blank line
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

            preParse.levelDescription = description;
            preParse.levelLayout = layout;
            preParse.enemyInfo = enemyInfo;
        }   
        return preParse;
    }

    public ParsedLevel ParseLevel(PreParse preParse)
    {
        ParsedLevel parsedLevel = new ParsedLevel();
        parsedLevel.tilePositions = new List<Vector3>();
        parsedLevel.enemyPositions = new Dictionary<Vector3, char>();
        parsedLevel.preEnemies = new Dictionary<char, PreEnemy>();
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
                        // to-do: end trigger
                        continue;
                    }
                    else
                    {
                        parsedLevel.enemyPositions.Add(position, tileCode);
                    }
                }
            }
        }
        // parse individual enemy information
        foreach (string[] enemyStrings in preParse.enemyInfo)
        {
            PreEnemy preEnemy = new PreEnemy();
            preEnemy.mainHandWeapon = "No Weapon";
            preEnemy.offHandWeapon = "No Weapon";
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
                else if (currentLine.StartsWith("unlockedSkills "))
                {
                    string enemyUnlockedSkills = currentLine.Substring("unlockedSkills ".Length);
                    int unlockedSkillsNumber;
                    if (Int32.TryParse(enemyUnlockedSkills, out unlockedSkillsNumber))
                    {
                        preEnemy.unlockedSkills = unlockedSkillsNumber;
                    }
                    else
                    {
                        Debug.LogError("unlockedSkills is not a number");
                    }
                }
                else if (currentLine.StartsWith("mainHandWeapon "))
                {
                    string enemyMainHandWeapon = currentLine.Substring("mainHandWeapon ".Length);
                    preEnemy.mainHandWeapon = enemyMainHandWeapon;
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
            }
            parsedLevel.preEnemies.Add(enemyCode, preEnemy);
        }

        return parsedLevel;
    }

    public void BuildLevel(ParsedLevel parsedLevel)
    {
        player.transform.position = parsedLevel.playerPosition; 
        
        for (int i = 0; i < parsedLevel.tilePositions.Count; i++)
        {
            GameObject newTile = Instantiate(tilePrefab, traversableTiles.transform);
            newTile.transform.position = parsedLevel.tilePositions[i];
            if (parsedLevel.tilePositions[i] == parsedLevel.playerPosition)
            {
                TileScript tileScript = newTile.GetComponent<TileScript>();
                tileScript.isOccupied = true;
                tileScript.IsRespawn = true;
            }
            if (parsedLevel.enemyPositions.ContainsKey(parsedLevel.tilePositions[i]))
            {
                newTile.GetComponent<TileScript>().isOccupied = true;
            }
        }

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
            newEnemyScript.MaxHealth = preEnemy.maxHealth;
            newEnemyScript.Armor = preEnemy.armor;
            newEnemyScript.Speed = preEnemy.speed;
            newEnemyScript.aggroRange = preEnemy.aggroRange;
            newEnemyScript.unlockedSkills = preEnemy.unlockedSkills;
            GameObject mainHandWeaponPrefab = Resources.Load<GameObject>("Prefabs/" + preEnemy.mainHandWeapon);
            GameObject offHandWeaponPrefab = Resources.Load<GameObject>("Prefabs/" + preEnemy.offHandWeapon);
            Transform enemyGear = newEnemy.transform.Find("Gear");
            Transform enemyMainHand = enemyGear.Find("Main Hand");
            Transform enemyOffHand = enemyGear.Find("Off Hand");
            GameObject enemyMainHandWeapon = Instantiate(mainHandWeaponPrefab, enemyMainHand);
            WeaponScript enemyMainHandWeaponScript = enemyMainHandWeapon.GetComponent<WeaponScript>();
            enemyMainHandWeaponScript.SetDamage(preEnemy.mainHandDamage);
            GameObject enemyOffHandWeapon = Instantiate(offHandWeaponPrefab, enemyOffHand);
            WeaponScript enemyOffHandWeaponScript = enemyOffHandWeapon.GetComponent<WeaponScript>();
            enemyOffHandWeaponScript.SetDamage(preEnemy.offHandDamage);
        }
    }

    void Start()
    {
        missionLogic = GameObject.Find("Mission Logic");
        missionLogicScript = missionLogic.GetComponent<MissionLogicScript>();
        levelName = missionLogicScript.currentLevelName;
        player = GameObject.Find("Player");
        enemies = GameObject.Find("Enemies");
        traversableTiles = GameObject.Find("Traversable Tiles");
        tilePrefab = Resources.Load<GameObject>("Prefabs/Tile");
        enemyPrefab = Resources.Load<GameObject>("Prefabs/Enemy");

        BuildLevel(ParseLevel(LoadLevelFile(levelName)));
        finishedBuilding = true;
    }
}
