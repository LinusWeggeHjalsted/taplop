using UnityEngine;
using System.Collections;

public class GearScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public Transform mainHand;
    public Transform offHand;
    
    void Start()
    {
        // to-do: delete this script and clean up
        mainHand = this.transform.Find("Main Hand");
        offHand = this.transform.Find("Off Hand");
        finishedBuilding = true;
    }
}
