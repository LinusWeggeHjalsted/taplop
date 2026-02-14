using UnityEngine;

public class BootsScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int speedBonus = 0;
    private int _inventoryPosition;
    public int inventoryPosition
    {
        get
        {
            return _inventoryPosition;
        }
        set
        {
            _inventoryPosition = value;
        }
    }

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

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = armorBonus + speedBonus;
        int fractionValue = totalValue / 2;
        salvage.cloth = fractionValue;
        salvage.leather = totalValue - fractionValue;
        return salvage;
    }

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/BootsItem");
        itemType = "Boots";
    }
}
