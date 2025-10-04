using UnityEngine;

public class SwordScript : MonoBehaviour, Weapon, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    public GameObject secondSkillPrefab;
    public GameObject secondSkill;
    public Sprite itemSprite;
    public string itemType;
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

    public Sprite GetSprite()
    {
        return itemSprite;
    }

    public string ItemType()
    {
        return itemType;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Slice");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Spinblade");
        secondSkill = Instantiate(secondSkillPrefab, this.transform); 
        itemSprite = Resources.Load<Sprite>("Items/SwordItem");
        itemType = "Main Hand Weapon";
        damage = 3;
        finishedBuilding = true;
    }
}
