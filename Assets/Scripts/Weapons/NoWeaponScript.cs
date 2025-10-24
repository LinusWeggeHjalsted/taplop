using UnityEngine;

public class NoWeaponScript : MonoBehaviour, WeaponScript, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    public string itemName; // to-do - will be set when instantiated
    public Sprite itemSprite;
    public string itemType;
    public string itemSubType;
    private int damage = 1; // to-do - will be set when instantiated

    public GameObject FirstSkill()
    {
        return firstSkill;
    }

    public GameObject SecondSkill()
    {
        return firstSkill;
    }

    public GameObject ThirdSkill()
    {
        return firstSkill;
    }

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

    public string ItemSubType()
    {
        return itemSubType;
    }

    public string ItemName()
    {
        return "None";
    }

    public string ItemDescription()
    {
        return "None";
    }

    public void SetItemName(string newItemName)
    {
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/No Skill");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/NoItem");
        itemType = "Weapon";
        itemSubType = "None";
        finishedBuilding = true;
    }
}
