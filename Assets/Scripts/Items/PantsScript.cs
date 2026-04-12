using UnityEngine;

public class PantsScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int healthBonus = 0;
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
        GameObject player = GameReferences.GetPlayer();
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        GameObject equippedPants = playerScript.pants;
        string healthDifferenceString = "";
        string pickupRadiusDifferenceString = "";

        if (equippedPants == null)
        {
            healthDifferenceString = $"<color=#00FF00>+{healthBonus.ToString()}</color>";
            pickupRadiusDifferenceString = $"<color=#00FF00>+{pickupRadius.ToString()}</color>";
        }
        else
        {
            PantsScript pantsScript = equippedPants.GetComponent<PantsScript>();
            int healthDifference = healthBonus - pantsScript.healthBonus;
            int pickupRadiusDifference = pickupRadius - pantsScript.pickupRadius;
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
            if (pickupRadiusDifference > 0)
            {
                pickupRadiusDifferenceString = $"<color=#00FF00>+{pickupRadiusDifference.ToString()}</color>";
            }
            else if (pickupRadiusDifference < 0)
            {
                pickupRadiusDifferenceString = $"<color=#FF0000>{pickupRadiusDifference.ToString()}</color>";
            }
            else
            {
                pickupRadiusDifferenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        string healthString = $"Health +{healthBonus.ToString()} <color=#FFFFFF80>[</color>{healthDifferenceString}<color=#FFFFFF80>]</color>";
        string pickupRadiusString = $"Pickup Radius +{pickupRadius.ToString()} <color=#FFFFFF80>[</color>{pickupRadiusDifferenceString}<color=#FFFFFF80>]</color>";
        return healthString + "\n" + pickupRadiusString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = healthBonus + pickupRadius;
        int fractionValue = totalValue / 2;
        salvage.leather = fractionValue;
        salvage.cloth = totalValue - fractionValue;
        return salvage;
    }

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/PantsItem");
        itemType = "Pants";
    }
}
