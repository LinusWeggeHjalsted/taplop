using UnityEngine;

public class CoatScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int healthBonus = 0;
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
        string healthString = "Health +" + healthBonus.ToString();
        return armorString + "\n" + healthString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = armorBonus + healthBonus;
        int fractionValue = totalValue / 2;
        salvage.leather = fractionValue;
        salvage.cloth = totalValue - fractionValue;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/CoatItem");
        itemType = "Coat";
    }
}
