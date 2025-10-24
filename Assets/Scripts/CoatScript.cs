using UnityEngine;

public class CoatScript : MonoBehaviour, ItemScript
{
    public Sprite itemSprite;
    public string itemName = "";
    public string itemType;
    public int armorBonus = 0;
    public int healthBonus = 0;

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
        string armorString = "Armor +" + armorBonus.ToString();
        string healthString = "Health +" + healthBonus.ToString();
        return armorString + "\n" + healthString;
    }

    public string ItemType()
    {
        return itemType;
    }

    void Start()
    {
        itemSprite = Resources.Load<Sprite>("Items/CoatItem");
        itemType = "Coat";
    }
}
