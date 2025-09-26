using UnityEngine;
using System;
using System.Collections.Generic;

public class LevelBuilderScript : MonoBehaviour
{
    public class PreParse
    {
        public string levelDescription;
        public char[][] levelLayout;
        public string enemyInformation;
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
    
    public Vector3 FindPlayerSpawnPosition(char[][] lvlLayout)
    {
        Vector3 position = new Vector3(0, 0, 0); 
        bool notFound = true;
        for (int i = 0; i < lvlLayout.Length; i++)
        {
            for (int j = 0; j < lvlLayout[i].Length; j++)
            {
                if (lvlLayout[i][j] == '!')
                {
                    position = new Vector3(j, lvlLayout.Length - 1 - i, 0);
                    // flipping y axis to match Unity
                    Debug.Log("Found player spawn position at " + position.ToString());
                    notFound = false;
                }
            }
        }
        if (notFound)
        {
            Debug.LogError("Couldn't find player spawn position");
        }
        return position;
    }
    
    public Dictionary<Vector3, char> FindEnemyPositions(char[][] lvlLayout)
    {

    }

    public List<Vector3> FindTilePositions(char[][] lvlLayout)
    {
        List<Vector3> positions = new List<Vector3>();
        for (int i = 0; i < lvlLayout.Length; i++)
        {
            for (int j = 0; j < lvlLayout[i].Length; j++)
            {
                if (lvlLayout[i][j] != ' ')
                {
                    Vector3 position = new Vector3(j, lvlLayout.Length - 1 - i, 0);
                    positions.Add(position);
                }
            }
        }
        if (positions.Count == 0)
        {
            Debug.LogError("No tiles found");
        }
        return positions;
    }

    public ParsedLevel ParseLevel(string lvlName)
    {
        ParsedLevel parsedLevel = new ParsedLevel();
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
            int descriptionIndex = Array.IndexOf(fileLines, "Level Description") + 1;
            int layoutIndex = Array.IndexOf(fileLines, "Level Layout") + 1;
            int enemiesIndex = Array.IndexOf(fileLines, "Enemies") + 1;
            // to-do: handle bad files

            int descriptionLength = layoutIndex - descriptionIndex - 2;
            int layoutLength = enemiesIndex - layoutIndex - 2;
            int enemiesLength = fileLines.Length - enemiesIndex - 2;

            string description = fileLines[descriptionIndex];
            string[] layoutBlock = new string[layoutLength];
            Array.Copy(fileLines, layoutIndex, layoutBlock, 0, layoutLength);
            char[][] layout = new char[layoutLength][];
            for (int i = 0; i < layoutLength; i++)
            {
                layout[i] = layoutBlock[i].ToCharArray();
            }
            parsedLevel.levelDescription = description;
            parsedLevel.levelLayout = layout;
        }   
        return parsedLevel;
    }

    public void BuildLevel(string lvlName)
    {
        ParsedLevel parsedLevel = ParseLevel(lvlName);
        List<Vector3> tilePositions = FindTilePositions(parsedLevel.levelLayout);
        Vector3 playerSpawnPosition = FindPlayerSpawnPosition(parsedLevel.levelLayout);
        player.transform.position = playerSpawnPosition; 
        for (int i = 0; i < tilePositions.Count; i++)
        {
            GameObject newTile = Instantiate(tilePrefab, traversableTiles.transform);
            newTile.transform.position = tilePositions[i];
            // update tile if it is occupied by player
            if (tilePositions[i] == playerSpawnPosition)
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
