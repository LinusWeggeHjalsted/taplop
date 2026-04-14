using UnityEngine;

public class SkillTomeScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string skillName;
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
        return skillName + " Tome";
    }

    public string ItemDescription()
    {
        PlayerDataScript playerDataScript = PlayerDataScript.Instance;
        string statusString = "";
        if (playerDataScript.unlockedSkills.Contains(skillName))
        {
            statusString = " [<color=#00FF00>Already learned</color>]";
        }
        else
        {
            statusString = " [<color=#FF0000>Double click to learn</color>]";
        }
        return "Learn " + skillName + statusString;
    }

    public string ItemType()
    {
        return "Tome";
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = 5;
        salvage.knowledge = totalValue;
        return salvage;
    }

    void Awake()
    {
        itemSprite = Resources.Load<Sprite>("Items/SkillTome");
    }
}
