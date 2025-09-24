using UnityEngine;

public class NoWeaponScript : MonoBehaviour, Weapon
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    public string itemName; // to-do - will be set when instantiated
    public int damage = 1; // to-do - will be set when instantiated

    public bool IsFinishedBuilding()
    {
        return finishedBuilding;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/No Skill");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        finishedBuilding = true;
    }
}
