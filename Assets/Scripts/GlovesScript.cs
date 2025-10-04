using UnityEngine;

public class GlovesScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int damageBonus = 0;
    
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
        itemSprite = Resources.Load<Sprite>("Items/GlovesItem");
        itemType = "Gloves";
    }
}
