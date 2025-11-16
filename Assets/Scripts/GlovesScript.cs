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

    public string ItemName()
    {
        return itemName;
    }

    public string ItemDescription()
    {
        string armorString = "Armor +" + armorBonus.ToString();
        string damageString = "Damage +" + damageBonus.ToString();
        return armorString + "\n" + damageString;
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
        salvage[2] = armorBonus + damageBonus;
        // knowledge
        salvage[3] = 0;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/GlovesItem");
        itemType = "Gloves";
    }
}
