using UnityEngine;
using System;
using System.Collections;
using System.Collections.Generic;


public class TurnLogicScript : MonoBehaviour
{
    public enum GameState
    {
        BuildingLevel,
        PlayerTurnMove,
        PlayerTurnAttack,
        EnemyTurn,
    }

    public GameState currentGameState;
    public GameObject player;
    public PlayerScript playerScript;
    public GameObject enemies;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();
    
    public bool hasMoved = false;

    IEnumerator WaitForLevelBuilderBeforeNewGameState()
    {
        while (!levelBuilderScript.finishedBuilding && !traversableTilesScript.finishedBuilding)
        {
            yield return null;
        }
        currentGameState = GameState.PlayerTurnMove;
        tileLookup = traversableTilesScript.tileLookup;
    }

    void Start()
    {
        currentGameState = GameState.BuildingLevel;
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerScript>();
        enemies = GameObject.Find("Enemies");
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        // wait for LevelBuilder to finish building
        StartCoroutine(WaitForLevelBuilderBeforeNewGameState());
    }

    void Update()
    {
        switch (currentGameState)
        {
            case GameState.BuildingLevel:
                break;
            case GameState.PlayerTurnMove:
                if (hasMoved) // clean up and change gamestate
                {
                    currentGameState = GameState.PlayerTurnAttack;
                    hasMoved = false;
                    GameObject newTile = tileLookup[player.transform.position];
                    TileScript newTileScript = newTile.GetComponent<TileScript>();
                    GameObject oldTile = tileLookup[playerScript.previousPosition];
                    TileScript oldTileScript = oldTile.GetComponent<TileScript>();
                    newTileScript.isOccupied = true;
                    oldTileScript.isOccupied = false;
                    
                    foreach (KeyValuePair<Vector3, GameObject> tile in tileLookup)
                    {
                        TileScript tileScript = tile.Value.GetComponent<TileScript>();
                        if (tileScript.isHighlighted)
                        {
                            tileScript.isHighlighted = false;
                        }
                        if (tileScript.isClickable)
                        {
                            tileScript.isClickable = false;
                        }
                    }
                    break;

                }
                // find reachable tiles
                int playerSpeed = playerScript.speed;
                Vector3 playerPosition = player.transform.position;
                List<Vector3> reachableTiles = new List<Vector3>();
                for (int i = -playerSpeed; i <= playerSpeed; i++)
                {
                    for (int j = -playerSpeed; j <= playerSpeed; j++)
                    {
                        Vector3 delta = new Vector3(i, j, 0);
                        Vector3 reachablePos = playerPosition + delta;
                        List<Vector3> shortestPath = traversableTilesScript.ShortestPath(playerPosition, reachablePos);
                        // check that tile exists, isn't occupied, and has a path from player
                        if (!tileLookup.ContainsKey(reachablePos))
                        {
                            continue;
                        }
                        if (tileLookup[reachablePos].GetComponent<TileScript>().isOccupied)
                        {
                            continue;
                        }
                        if (shortestPath == null)
                        {
                            continue;
                        }
                        if (shortestPath.Count > playerSpeed)
                        {
                            continue;
                        }
                        else
                        {
                            reachableTiles.Add(reachablePos);
                        }
                    }
                }
                
                foreach (Vector3 pos in reachableTiles)
                {
                    TileScript tileScript = tileLookup[pos].GetComponent<TileScript>();
                    tileScript.isHighlighted = true;
                    tileScript.isClickable = true;
                }
                // await player input

                break;
            case GameState.PlayerTurnAttack:
                // select skill, select targets, update level
                break;
            case GameState.EnemyTurn:
                // execute ai per active enemy
                break;
        }
    }
}
