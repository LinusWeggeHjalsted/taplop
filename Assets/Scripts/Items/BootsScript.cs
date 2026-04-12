using UnityEngine;

public class BootsScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int healthBonus = 0;
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
        string healthDifferenceString = "";
        string speedDifferenceString = "";

        if (equippedBoots == null)
        {
            healthDifferenceString = $"<color=#00FF00>+{healthBonus.ToString()}</color>";
            speedDifferenceString = $"<color=#00FF00>+{speedBonus.ToString()}</color>";
        }
        else
        {
            BootsScript bootsScript = equippedBoots.GetComponent<BootsScript>();
            int healthDifference = healthBonus - bootsScript.healthBonus;
            int speedDifference = speedBonus - bootsScript.speedBonus;
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

        string healthString = $"Health +{healthBonus.ToString()} <color=#FFFFFF80>[</color>{healthDifferenceString}<color=#FFFFFF80>]</color>";
        string speedString = $"Speed +{speedBonus.ToString()} <color=#FFFFFF80>[</color>{speedDifferenceString}<color=#FFFFFF80>]</color>";
        return healthString + "\n" + speedString;
    }
    
    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = healthBonus + speedBonus;
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
