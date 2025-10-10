using UnityEngine;
using System.Collections;

public class GearScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public Transform mainHand;
    public Transform offHand;
    public GameObject mainHandWeapon;
    public GameObject offHandWeapon;
    public WeaponScript mainHandWeaponScript;
    public WeaponScript offHandWeaponScript;

    IEnumerator WaitForWeapons()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }

        mainHandWeapon = mainHand.GetChild(0).gameObject;
        offHandWeapon = offHand.GetChild(0).gameObject;
        mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
        offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();

        while (!(mainHandWeaponScript.IsFinishedBuilding() && offHandWeaponScript.IsFinishedBuilding()))
        {
            yield return null;
        }

        finishedBuilding = true;
    }

    void Start()
    {
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        mainHand = this.transform.Find("Main Hand");
        offHand = this.transform.Find("Off Hand");
        StartCoroutine(WaitForWeapons());
    }
}
