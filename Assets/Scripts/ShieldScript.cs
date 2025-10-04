using UnityEngine;

public class ShieldScript : MonoBehaviour, Weapon, OffHandScript, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    private GameObject firstSkill;
    public Sprite itemSprite;
    public string itemType;
    private int damage = 1;

    public GameObject FirstSkill()
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

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Reflect");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/ShieldItem");
        itemType = "Off Hand Weapon";
        finishedBuilding = true;
    }
}
