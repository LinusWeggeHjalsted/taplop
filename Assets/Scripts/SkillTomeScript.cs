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
        return "Learn " + skillName;
    }

    public string ItemType()
    {
        return "Tome";
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        salvage.knowledge = 1;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/SkillTome");
    }
}
