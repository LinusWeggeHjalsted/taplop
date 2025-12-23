using UnityEngine;

public class PantsScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int pickupRadius = 0;
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
        string pickupRadiusString = "Pickup Radius +" + pickupRadius.ToString();
        return armorString + "\n" + pickupRadiusString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = armorBonus + pickupRadius;
        int fractionValue = totalValue / 2;
        salvage.leather = fractionValue;
        salvage.cloth = totalValue - fractionValue;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/PantsItem");
        itemType = "Pants";
    }
}
