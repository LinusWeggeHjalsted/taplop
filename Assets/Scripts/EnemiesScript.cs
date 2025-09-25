using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class EnemiesScript : MonoBehaviour
{
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject player;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();
    public Dictionary<Vector3, GameObject> enemyLookup = new Dictionary<Vector3, GameObject>();

    IEnumerator WaitForLevelBuilderBeforePopulating()
    {
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
            float enemyMinRange = (float)enemyScript.minRange;
            if (distanceToPlayer <= enemyMinRange)
            {
                return;
            }
            // go as far as it can, but stop short of player
            Vector3 targetPosition = playerPosition;
            if (pathLength > 1)
            {
                if (enemySpeed >= pathLength)
                {
                    targetPosition = pathToPlayer[1];
                }
                else
                {
                    targetPosition = pathToPlayer[-enemySpeed];
                }
            }
            // check for collision
            if (tileLookup[targetPosition].isOccupied)
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
