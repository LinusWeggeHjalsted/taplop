using UnityEngine;

public class GlovesScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int healthBonus = 0;
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
        string healthDifferenceString = "";
        string damageDifferenceString = "";

        if (equippedGloves == null)
        {
            healthDifferenceString = $"<color=#00FF00>+{healthBonus.ToString()}</color>";
            damageDifferenceString = $"<color=#00FF00>+{damageBonus.ToString()}</color>";
        }
        else
        {
            GlovesScript glovesScript = equippedGloves.GetComponent<GlovesScript>();
            int healthDifference = healthBonus - glovesScript.healthBonus;
            int damageDifference = damageBonus - glovesScript.damageBonus;
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

        string healthString = $"Health +{healthBonus.ToString()} <color=#FFFFFF80>[</color>{healthDifferenceString}<color=#FFFFFF80>]</color>";
        string damageString = $"Damage +{damageBonus.ToString()} <color=#FFFFFF80>[</color>{damageDifferenceString}<color=#FFFFFF80>]</color>";
        return healthString + "\n" + damageString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = healthBonus + damageBonus;
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
