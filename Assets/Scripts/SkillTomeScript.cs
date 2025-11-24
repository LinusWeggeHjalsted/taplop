using UnityEngine;

public class SkillTomeScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string skillName;

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

    public int[] SalvageValue()
    {
        int[] salvage = new int[4];
        // wood
        salvage[0] = 0;
        // metal
        salvage[1] = 0;
        // leather
        salvage[2] = 0;
        // knowledge
        salvage[3] = 1;
        return salvage;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/SkillTome");
    }
}
