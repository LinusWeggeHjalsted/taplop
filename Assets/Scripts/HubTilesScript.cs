using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class HubTilesScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject hubBuilder;
    public HubBuilderScript hubBuilderScript;
    public Dictionary<Vector3, GameObject> tileLookup;

    IEnumerator WaitForHubBuilder()
    {
        while (!hubBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        // populate tileLookup
        tileLookup = new Dictionary<Vector3, GameObject>();
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject tile = this.transform.GetChild(i).gameObject;
            tileLookup.Add(tile.transform.position, tile);
        }
        finishedBuilding = true;
    }

    void Start()
    {
        hubBuilder = GameObject.Find("Hub Builder");
        hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        StartCoroutine(WaitForHubBuilder());
    }
}
