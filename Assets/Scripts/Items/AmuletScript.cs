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
        GameObject player = GameReferences.GetPlayer();
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        GameObject equippedAmulet = playerScript.amulet;
        string differenceString = "";

        if (equippedAmulet == null)
        {
            differenceString = $"<color=#00FF00>+{spellDamage.ToString()}</color>";
        }
        else
        {
            AmuletScript amuletScript = equippedAmulet.GetComponent<AmuletScript>();
            int difference = spellDamage - amuletScript.spellDamage;
            if (difference > 0)
            {
                differenceString = $"<color=#00FF00>+{difference.ToString()}</color>";
            }
            else if (difference < 0)
            {
                differenceString = $"<color=#FF0000>{difference.ToString()}</color>";
            }
            else
            {
                differenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        string spellDamageString = $"Spell Damage {spellDamage.ToString()} <color=#FFFFFF80>[</color>{differenceString}<color=#FFFFFF80>]</color>";
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

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/AmuletItem");
        itemType = "Amulet";
    }
}
