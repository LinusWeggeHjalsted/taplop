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
        GameObject player = GameReferences.GetPlayer();
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        GameObject equippedBoots = playerScript.boots;
        string armorDifferenceString = "";
        string speedDifferenceString = "";

        if (equippedBoots == null)
        {
            armorDifferenceString = $"<color=#00FF00>+{armorBonus.ToString()}</color>";
            speedDifferenceString = $"<color=#00FF00>+{speedBonus.ToString()}</color>";
        }
        else
        {
            BootsScript bootsScript = equippedBoots.GetComponent<BootsScript>();
            int armorDifference = armorBonus - bootsScript.armorBonus;
            int speedDifference = speedBonus - bootsScript.speedBonus;
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
            if (speedDifference > 0)
            {
                speedDifferenceString = $"<color=#00FF00>+{speedDifference.ToString()}</color>";
            }
            else if (speedDifference < 0)
            {
                speedDifferenceString = $"<color=#FF0000>{speedDifference.ToString()}</color>";
            }
            else
            {
                speedDifferenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        string armorString = $"Armor +{armorBonus.ToString()} <color=#FFFFFF80>[</color>{armorDifferenceString}<color=#FFFFFF80>]</color>";
        string speedString = $"Speed +{speedBonus.ToString()} <color=#FFFFFF80>[</color>{speedDifferenceString}<color=#FFFFFF80>]</color>";
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
