using UnityEngine;

public class ShieldScript : MonoBehaviour, Weapon, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    public GameObject firstSkill;
    public Sprite itemSprite;
    public string itemType;
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
        itemSprite = Resources.Load<Sprite>("Items/ShieldItem");
        itemType = "Off Hand Weapon";
        finishedBuilding = true;
    }
}
