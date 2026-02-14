using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class DropsScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public Dictionary<Vector3, GameObject> groundItemsLookup;

    IEnumerator WaitForLevelBuilderBeforePopulating()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject groundItems = this.transform.GetChild(i).gameObject;
            groundItemsLookup.Add(groundItems.transform.position, groundItems);
        }
        finishedBuilding = true;
    }

    void Awake()
    {
        groundItemsLookup = new Dictionary<Vector3, GameObject>();
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            levelBuilder = LevelScript.Instance.levelBuilder;
            if (levelBuilder != null) levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        }
        StartCoroutine(WaitForLevelBuilderBeforePopulating());
    }
}
