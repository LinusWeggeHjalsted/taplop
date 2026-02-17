using UnityEngine;

public class GlovesScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int damageBonus = 0;
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
        GameObject equippedGloves = playerScript.gloves;
        string armorDifferenceString = "";
        string damageDifferenceString = "";

        if (equippedGloves == null)
        {
            armorDifferenceString = $"<color=#00FF00>+{armorBonus.ToString()}</color>";
            damageDifferenceString = $"<color=#00FF00>+{damageBonus.ToString()}</color>";
        }
        else
        {
            GlovesScript glovesScript = equippedGloves.GetComponent<GlovesScript>();
            int armorDifference = armorBonus - glovesScript.armorBonus;
            int damageDifference = damageBonus - glovesScript.damageBonus;
            if (armorDifference > 0)
            {
                armorDifferenceString = $"<color=#00FF00>+{armorDifference.ToString()}</color>";
            }
            else if (armorDifference < 0)
            {
                armorDifferenceString = $"<color=#FF0000>{armorDifference.ToString()}</color>";
            }
            else
            {
                armorDifferenceString = "<color=#FFFFFF80>0</color>";
            }
            if (damageDifference > 0)
            {
                damageDifferenceString = $"<color=#00FF00>+{damageDifference.ToString()}</color>";
            }
            else if (damageDifference < 0)
            {
                damageDifferenceString = $"<color=#FF0000>{damageDifference.ToString()}</color>";
            }
            else
            {
                damageDifferenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        string armorString = $"Armor +{armorBonus.ToString()} <color=#FFFFFF80>[</color>{armorDifferenceString}<color=#FFFFFF80>]</color>";
        string damageString = $"Damage +{damageBonus.ToString()} <color=#FFFFFF80>[</color>{damageDifferenceString}<color=#FFFFFF80>]</color>";
        return armorString + "\n" + damageString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = armorBonus + damageBonus;
        int fractionValue = totalValue / 2;
        salvage.cloth = fractionValue;
        salvage.leather = totalValue - fractionValue;
        return salvage;
    }

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/GlovesItem");
        itemType = "Gloves";
    }
}
