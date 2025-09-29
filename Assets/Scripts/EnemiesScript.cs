using UnityEngine;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class EnemiesScript : MonoBehaviour
{
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject player;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();
    public Dictionary<Vector3, GameObject> enemyLookup = new Dictionary<Vector3, GameObject>();
    public Dictionary<Vector3, GameObject> activeEnemyLookup = new Dictionary<Vector3, GameObject>();

    IEnumerator WaitForLevelBuilderBeforePopulating()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        while (!traversableTilesScript.finishedBuilding)
        {
            yield return null;
        }
        tileLookup = traversableTilesScript.tileLookup;
        // populate enemyLookup
        for (int i = 0; i < this.transform.childCount; i++)
        {
            Transform enemyTransform = this.transform.GetChild(i);
            GameObject enemy = enemyTransform.gameObject;
            enemyLookup.Add(enemyTransform.position, enemy);
            GameObject tile = tileLookup[enemyTransform.position];
            TileScript tileScript = tile.GetComponent<TileScript>();
            tileScript.isOccupied = true;
            Debug.Log("found enemy at " + enemyTransform.position.ToString());
        }
    }

    void Start()
    {
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        player = GameObject.Find("Player");
        // wait for level builder
        StartCoroutine(WaitForLevelBuilderBeforePopulating());
    }

    public void UpdateAggro()
    {
        foreach (GameObject enemy in enemyLookup.Values)
        {
            // to-do: deaggro when player is far away
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            if (!enemyScript.IsActive)
            {
                Vector3 playerPosition = player.transform.position;
                Vector3 enemyPosition = enemy.transform.position;
                int aggroRange = enemyScript.aggroRange;
                Debug.Log("aggroRange is " + aggroRange.ToString());
                if (traversableTilesScript.Distance(playerPosition, enemyPosition) <= (float)aggroRange)
                {
                    enemyScript.IsActive = true;
                    activeEnemyLookup.Add(enemyPosition, enemy);
                }
            }
        }
    }

    public void EnemyMoved(Vector3 currentPosition, Vector3 targetPosition)
    {
        GameObject enemyObject = enemyLookup[currentPosition];
        enemyLookup.Add(targetPosition, enemyObject);
        enemyLookup.Remove(currentPosition);
        if (activeEnemyLookup.ContainsKey(currentPosition))
        {
            activeEnemyLookup.Add(targetPosition, enemyObject);
            activeEnemyLookup.Remove(currentPosition);
        }
    }

    public void KillDeadEnemies()
    {
        List<GameObject> enemyObjects = enemyLookup.Values.ToList();
        foreach (GameObject enemy in enemyObjects)
        {
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            if (enemyScript.CurrentHealth <= 0)
            {
                Vector3 enemyPosition = enemy.transform.position;
                enemyLookup.Remove(enemyPosition);
                if (activeEnemyLookup.ContainsKey(enemyPosition))
                {
                    activeEnemyLookup.Remove(enemyPosition);
                }
                GameObject tile = tileLookup[enemyPosition];
                TileScript tileScript = tile.GetComponent<TileScript>();
                tileScript.isOccupied = false;
                Destroy(enemy);
            }
        }
    }

    public void EnemyTurnMove(GameObject enemy)
    {
        Vector3 enemyPosition = enemy.transform.position;
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(enemyPosition, playerPosition);
        List<Vector3> pathToPlayer = traversableTilesScript.ShortestPath(enemyPosition, playerPosition);
        int pathLength = pathToPlayer.Count;
        if (pathToPlayer != null)
        {
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            int enemySpeed = enemyScript.speed;
            float enemyMinRange = enemyScript.minRange;
            if (distanceToPlayer <= enemyMinRange)
            {
                return;
            }
            // go as far as it can, but stop short of player
            Vector3 targetPosition = playerPosition;
            if (pathLength > 1)
            {
                if (enemySpeed >= pathLength - 1)
                {
                    targetPosition = pathToPlayer[1];
                }
                else
                {
                    Debug.Log("enemySpeed is " + enemySpeed.ToString());
                    Debug.Log("pathLength is " + pathLength.ToString());
                    int targetIndex = pathLength - enemySpeed;
                    targetPosition = pathToPlayer[targetIndex];
                }
            }
            GameObject targetTile = tileLookup[targetPosition];
            TileScript targetTileScript = targetTile.GetComponent<TileScript>();
            if (targetTileScript.isOccupied)
            {
                // to-do: try going around
                return;
            }
            else
            {
                enemyScript.MoveTo(targetPosition);
            }
        }
    }
}
