using UnityEngine;
using TMPro;
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
        EnemiesTurn,
    }

    public GameObject player;
    public EntityScript playerScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public TMP_Text turnStatusText;
    public GameObject skillsPanel;
    public SkillsPanelScript skillsPanelScript;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();
    
    public GameState currentGameState;
    public GameObject skillUsed;
    public bool hasMoved = false;
    public bool hasAttacked = false;
    public bool turnStarted = false;

    IEnumerator WaitForBuildingBeforeNewGameState()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        while (!traversableTilesScript.finishedBuilding)
        {
            yield return null;
        }
        while (!skillsPanelScript.finishedBuilding)
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
        playerScript = player.GetComponent<EntityScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        turnStatusText = GameObject.Find("Turn Status Text").GetComponent<TMP_Text>();
        skillsPanel = GameObject.Find("Skills Panel");
        skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
        // wait for LevelBuilder to finish building
        StartCoroutine(WaitForBuildingBeforeNewGameState());
    }
    
    public void RespawnPlayer()
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        Vector3 respawnPosition = new Vector3();
        foreach (GameObject tile in tileLookup.Values)
        {
            TileScript tileScript = tile.GetComponent<TileScript>();
            if (tileScript.IsRespawn)
            {
                respawnPosition = tile.transform.position;
            }
        }
        playerScript.MoveTo(respawnPosition);
        playerScript.CurrentHealth = playerScript.maxHealth;
    }

    IEnumerator PlayerTurnMove()
    {
        hasMoved = false;
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
            tileScript.IsHighlighted = true;
        }
        while (!hasMoved)
        {
            yield return null;
        }
        GameObject newTile = tileLookup[player.transform.position];
        TileScript newTileScript = newTile.GetComponent<TileScript>();
        GameObject oldTile = tileLookup[playerScript.previousPosition];
        TileScript oldTileScript = oldTile.GetComponent<TileScript>();
        newTileScript.isOccupied = true;
        oldTileScript.isOccupied = false;        
        currentGameState = GameState.PlayerTurnAttack;
        hasMoved = false;
        turnStarted = false;
    }

    IEnumerator PlayerTurnAttack()
    {
        hasAttacked = false;
        while (!hasAttacked)
        {
            yield return null;
        }
        
        enemiesScript.KillDeadEnemies();
        currentGameState = GameState.EnemiesTurn;
        hasAttacked = false;
        turnStarted = false;
    }

    IEnumerator EnemiesTurn()
    {
        Dictionary<Vector3, GameObject> activeEnemyLookup = new Dictionary<Vector3, GameObject>(enemiesScript.activeEnemyLookup);
        Debug.Log(activeEnemyLookup.Count.ToString() + " active enemies");
        foreach (GameObject enemy in activeEnemyLookup.Values)
        {
            Debug.Log(enemy.name + " is taking its turn");
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            enemyScript.ReduceCooldowns(1);
            enemyScript.ReduceEffectDurations(1);
            enemiesScript.EnemyTurnMove(enemy);
            yield return new WaitForSeconds(0.25f);
            enemiesScript.EnemyTurnAttack(enemy);
            yield return new WaitForSeconds(0.25f);
        }
        currentGameState = GameState.PlayerTurnMove;
        turnStarted = false;
    }

    void Update()
    {
        switch (currentGameState)
        {
            case GameState.BuildingLevel:
                break;
            case GameState.PlayerTurnMove:
                if (!hasMoved)
                {
                    if (!turnStarted)
                    {
                        turnStarted = true;
                        if (playerScript.CurrentHealth <= 0)
                        {
                            RespawnPlayer();
                        }
                        playerScript.ReduceCooldowns(1);
                        playerScript.ReduceEffectDurations(1);
                        traversableTilesScript.ClearHighlights();
                        turnStatusText.text = "Move!";
                        StartCoroutine(PlayerTurnMove());
                    }
                }
                break;
            case GameState.PlayerTurnAttack:
                if (!hasAttacked)
                {
                    if (!turnStarted)
                    {
                        turnStarted = true;
                        traversableTilesScript.ClearHighlights();
                        turnStatusText.text = "Attack!";
                        StartCoroutine(PlayerTurnAttack());
                    }
                }
                break;
            case GameState.EnemiesTurn:
                if (!turnStarted)
                {
                    Debug.Log("enemies turn started");
                    turnStarted = true;
                    traversableTilesScript.ClearHighlights();
                    turnStatusText.text = "Enemies' turn...";
                    StartCoroutine(EnemiesTurn());
                }
                break;
        }
    }
}
