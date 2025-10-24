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

    public string ItemName()
    {
        return itemName;
    }

    public string ItemDescription()
    {
        string armorString = "Armor +" + armorBonus.ToString();
        string speedString = "Speed +" + speedBonus.ToString();
        return armorString + "\n" + speedString;
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
