using UnityEngine;

public class AmuletScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int spellDamage = 0;
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
        string spellDamageString = "Spell damage +" + spellDamage.ToString();
        return spellDamageString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = spellDamage;
        salvage.knowledge = totalValue;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/AmuletItem");
        itemType = "Amulet";
    }
}
