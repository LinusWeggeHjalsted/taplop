using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class EnemiesScript : MonoBehaviour
{
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
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
        // wait for level builder
        StartCoroutine(WaitForLevelBuilderBeforePopulating());
    }
}
