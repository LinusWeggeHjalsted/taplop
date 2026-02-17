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
        GameObject player = GameReferences.GetPlayer();
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        GameObject equippedCoat = playerScript.coat;
        string armorDifferenceString = "";
        string healthDifferenceString = "";

        if (equippedCoat == null)
        {
            armorDifferenceString = $"<color=#00FF00>+{armorBonus.ToString()}</color>";
            healthDifferenceString = $"<color=#00FF00>+{healthBonus.ToString()}</color>";
        }
        else
        {
            CoatScript coatScript = equippedCoat.GetComponent<CoatScript>();
            int armorDifference = armorBonus - coatScript.armorBonus;
            int healthDifference = healthBonus - coatScript.healthBonus;
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
            if (healthDifference > 0)
            {
                healthDifferenceString = $"<color=#00FF00>+{healthDifference.ToString()}</color>";
            }
            else if (healthDifference < 0)
            {
                healthDifferenceString = $"<color=#FF0000>{healthDifference.ToString()}</color>";
            }
            else
            {
                healthDifferenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        string armorString = $"Armor +{armorBonus.ToString()} <color=#FFFFFF80>[</color>{armorDifferenceString}<color=#FFFFFF80>]</color>";
        string healthString = $"Health +{healthBonus.ToString()} <color=#FFFFFF80>[</color>{healthDifferenceString}<color=#FFFFFF80>]</color>";
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

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/CoatItem");
        itemType = "Coat";
    }
}
