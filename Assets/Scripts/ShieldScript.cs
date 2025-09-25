using UnityEngine;

public class ShieldScript : MonoBehaviour, Weapon
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;

    public bool IsFinishedBuilding()
    {
        return finishedBuilding;
    }

    void Start()
    {
        finishedBuilding = true;
    }
}
