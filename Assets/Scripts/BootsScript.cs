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

    public int[] SalvageValue()
    {
        int[] salvage = new int[4];
        // wood
        salvage[0] = 0;
        // metal
        salvage[1] = 0;
        // leather
        salvage[2] = armorBonus + speedBonus;
        // knowledge
        salvage[3] = 0;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/BootsItem");
        itemType = "Boots";
    }
}
