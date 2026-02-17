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
        GameObject player = GameReferences.GetPlayer();
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        GameObject equippedPants = playerScript.pants;
        string armorDifferenceString = "";
        string pickupRadiusDifferenceString = "";

        if (equippedPants == null)
        {
            armorDifferenceString = $"<color=#00FF00>+{armorBonus.ToString()}</color>";
            pickupRadiusDifferenceString = $"<color=#00FF00>+{pickupRadius.ToString()}</color>";
        }
        else
        {
            PantsScript pantsScript = equippedPants.GetComponent<PantsScript>();
            int armorDifference = armorBonus - pantsScript.armorBonus;
            int pickupRadiusDifference = pickupRadius - pantsScript.pickupRadius;
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

        string armorString = $"Armor +{armorBonus.ToString()} <color=#FFFFFF80>[</color>{armorDifferenceString}<color=#FFFFFF80>]</color>";
        string pickupRadiusString = $"Pickup Radius +{pickupRadius.ToString()} <color=#FFFFFF80>[</color>{pickupRadiusDifferenceString}<color=#FFFFFF80>]</color>";
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

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/PantsItem");
        itemType = "Pants";
    }
}
