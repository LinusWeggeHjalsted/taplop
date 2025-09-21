using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class EnemiesScript : MonoBehaviour
{
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public Dictionary<Vector3, GameObject> enemyLookup = new Dictionary<Vector3, GameObject>();

    IEnumerator WaitForLevelBuilderBeforePopulating()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        // populate enemyLookup
        for (int i = 0; i < this.transform.childCount; i++)
        {
            Transform enemyTransform = this.transform.GetChild(i);
            GameObject enemy = enemyTransform.gameObject;
            enemyLookup.Add(enemyTransform.position, enemy);
        }
    }

    void Start()
    {
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        // wait for level builder
        StartCoroutine(WaitForLevelBuilderBeforePopulating());
    }
}
