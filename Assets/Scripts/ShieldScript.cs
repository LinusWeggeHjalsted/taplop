using UnityEngine;

public class ShieldScript : MonoBehaviour, Weapon
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    private int damage = 1;

    public bool IsFinishedBuilding()
    {
        return finishedBuilding;
    }

    public int GetDamage()
    {
        return damage;
    }

    public void SetDamage(int number)
    {
        damage = number;
    }

    void Start()
    {
        finishedBuilding = true;
    }
}
