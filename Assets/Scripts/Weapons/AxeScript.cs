using UnityEngine;

public class AxeScript : MonoBehaviour, WeaponScript, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    private GameObject firstSkill;
    public GameObject secondSkillPrefab;
    private GameObject secondSkill;
    public GameObject thirdSkillPrefab;
    private GameObject thirdSkill;
    public Sprite itemSprite;
    public string itemType;
    public string itemSubType;
    public string itemName;
    private int damage;
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

    public GameObject FirstSkill()
    {
        return firstSkill;
    }

    public GameObject SecondSkill()
    {
        return secondSkill;
    }

    public GameObject ThirdSkill()
    {
        return thirdSkill;
    }

    public bool IsFinishedBuilding()
    {
        return finishedBuilding;
    }

    public int GetDamage()
    {
        return damage;
    }

    public void SetDamage(int number)
    {
        damage = number;
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
        string damageString = "Damage " + damage.ToString();
        return damageString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public string ItemSubType()
    {
        return itemSubType;
    }

    public void SetItemName(string newItemName)
    {
        itemName = newItemName;
    }

    public int[] SalvageValue()
    {
        int[] salvage = new int[4];
        // wood
        salvage[0] = 0;
        // metal
        salvage[1] = damage;
        // leather
        salvage[2] = 0;
        // knowledge
        salvage[3] = 0;
        return salvage;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Chop");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Cleave");
        secondSkill = Instantiate(secondSkillPrefab, this.transform);
        thirdSkillPrefab = Resources.Load<GameObject>("Prefabs/Throw");
        thirdSkill = Instantiate(thirdSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/AxeItem");
        itemType = "Weapon";
        itemSubType = "Axe";
        finishedBuilding = true;
    }
}
