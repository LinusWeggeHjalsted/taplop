using UnityEngine;
using System.Collections;

public class GearScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public Transform mainHand;
    public Transform offHand;
    
    void Start()
    {
        // to-do: delete this script and clean up
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        mainHand = this.transform.Find("Main Hand");
        offHand = this.transform.Find("Off Hand");
        finishedBuilding = true;
    }
}
