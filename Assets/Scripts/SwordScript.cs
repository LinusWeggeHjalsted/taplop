using UnityEngine;

public class SwordScript : MonoBehaviour, Weapon
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    public GameObject secondSkillPrefab;
    public GameObject secondSkill;
    public string itemName; // to-do - will be set when instantiated
    public int damage = 1; // to-do - will be set when instantiated

    public bool IsFinishedBuilding()
    {
        return finishedBuilding;
    }

    public void SetDamage(int number)
    {
        damage = number;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Slice");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Spinblade");
        secondSkill = Instantiate(secondSkillPrefab, this.transform); 
        damage = 3;
        finishedBuilding = true;
    }
}
