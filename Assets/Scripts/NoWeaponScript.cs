using UnityEngine;

public class NoWeaponScript : MonoBehaviour, Weapon
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    public string itemName; // to-do - will be set when instantiated
    private int damage = 1; // to-do - will be set when instantiated

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
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/No Skill");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        finishedBuilding = true;
    }
}
