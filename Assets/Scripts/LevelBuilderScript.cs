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
        public string[][] enemyInfo;
    }

    public class PreEnemy
    {
        public string enemyName;
        public int maxHealth;
        public int speed;
        public int aggroRange;
    }

    public class ParsedLevel
    {
        public List<Vector3> tilePositions;
        public Vector3 playerPosition;
        public Dictionary<Vector3, char> enemyPositions;
        public List<PreEnemy> preEnemies;
    }
    
    public bool finishedBuilding = false;
    public GameObject level;
    public LevelScript levelScript;
    public string levelName;
    public GameObject player;
    public GameObject enemies;
    public GameObject traversableTiles;
    public GameObject tilePrefab;

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
            int layoutIndex = Array.IndexOf(fileLines, "Layout") + 1;
            int enemyInfoIndex = Array.IndexOf(fileLines, "Enemy Info") + 1;
            // to-do: handle bad files

            int descriptionLength = layoutIndex - descriptionIndex - 2;
            int layoutLength = enemyInfoIndex - layoutIndex - 2;
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
        parsedLevel.enemyPositions = new Dictionary<Vector3, char>;
        for (int i = 0; i < preParse.layout.Length; i++)
        {
            for (int j = 0; j < preParse.layout[i].Length; j++)
            {
                // flip y axis
                Vector3 position = new Vector3(j, preParse.layout.Length - i, 0);
                char tileCode = preParse.layout[i][j];
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
                    }
                    else
                    {
                        enemyPositions.Add(position, tileCode);
                    }
                }
            }
        }
        // find unique enemy types
        List<char> enemyTypes = parsedLevel.enemyPositions.Values.Distinct().ToList();
        Dictionary<char, int> codeIndices = new Dictionary<char, int>();
        foreach (char enemyCode in enemyTypes)
        {
            int lineIndex = preParse.enemies.IndexOf(enemyCode.ToString());
            if ()
            codeIndices.Add(enemyCode, lineIndex);
        }
        List<>
    }

    public void BuildLevel(ParsedLevel parsedLevel)
    {
        player.transform.position = parsedLevel.playerPosition; 
        
        for (int i = 0; i < parsedLevel.tilePositions.Count; i++)
        {
            GameObject newTile = Instantiate(tilePrefab, traversableTiles.transform);
            newTile.transform.position = parsedLevel.tilePositions[i];
            if (tilePositions[i] == parsedLevel.playerPosition)
            {
                newTile.GetComponent<TileScript>().isOccupied = true;
            }
            if (parsedLevel.enemyPositions.ContainsKey(tilePositions[i]))
            {
                newTile.GetComponent<TileScript>().isOccupied = true;
            }
        }
    }

    void Start()
    {
        level = GameObject.Find("Level");
        levelScript = level.GetComponent<LevelScript>();
        levelName = levelScript.levelName;
        player = GameObject.Find("Player");
        enemies = GameObject.Find("Enemies");
        traversableTiles = GameObject.Find("Traversable Tiles");
        tilePrefab = Resources.Load<GameObject>("Prefabs/Tile");

        BuildLevel(levelName);
        finishedBuilding = true;
    }

}
