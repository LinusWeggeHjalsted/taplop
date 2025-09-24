using UnityEngine;
using System.Collections;

public class GearScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public Transform mainHand;
    public Transform offHand;
    public GameObject mainHandWeapon;
    public GameObject offHandWeapon;
    public Weapon mainHandWeaponScript;
    public Weapon offHandWeaponScript;

    IEnumerator WaitForWeapons()
    {
        while (!(mainHandWeaponScript.IsFinishedBuilding() && offHandWeaponScript.IsFinishedBuilding()))
        {
            yield return null;
        }
        finishedBuilding = true;
    }

    void Start()
    {
        mainHand = this.transform.Find("Main Hand");
        offHand = this.transform.Find("Off Hand");
        mainHandWeapon = mainHand.GetChild(0).gameObject;
        offHandWeapon = offHand.GetChild(0).gameObject;
        mainHandWeaponScript = mainHandWeapon.GetComponent<Weapon>();
        offHandWeaponScript = offHandWeapon.GetComponent<Weapon>();
        StartCoroutine(WaitForWeapons());
    }
}
