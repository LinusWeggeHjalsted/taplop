using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class HubExitsScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject hubBuilder;
    public HubBuilderScript hubBuilderScript;
    public Dictionary<Vector3, GameObject> exitLookup;

    IEnumerator WaitForHubBuilder()
    {
        while (!hubBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        exitLookup = new Dictionary<Vector3, GameObject>();
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject exit = this.transform.GetChild(i).gameObject;
            exitLookup.Add(exit.transform.position, exit);
        }
        finishedBuilding = true;
    }

    void Start()
    {
        if (HubScript.Instance != null)
        {
            hubBuilder = HubScript.Instance.hubBuilder;
            hubBuilderScript = HubScript.Instance.hubBuilderScript;
        }
        StartCoroutine(WaitForHubBuilder());
    }
}
