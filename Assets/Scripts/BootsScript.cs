using UnityEngine;

public class BootsScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int speedBonus = 0;

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
        itemSprite = Resources.Load<Sprite>("Items/BootsItem");
        itemType = "Boots";
    }
}
