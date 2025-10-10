using UnityEngine;

public class ShieldScript : MonoBehaviour, WeaponScript, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    private GameObject firstSkill;
    public GameObject thirdSkillPrefab;
    private GameObject thirdSkill;
    public Sprite itemSprite;
    public string itemType;
    private int damage = 1;

    public GameObject FirstSkill()
    {
        return firstSkill;
    }

    public GameObject SecondSkill()
    {
        return thirdSkill; // to-do
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

    public string ItemType()
    {
        return itemType;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Bash");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        thirdSkillPrefab = Resources.Load<GameObject>("Prefabs/Reflect");
        thirdSkill = Instantiate(thirdSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/ShieldItem");
        itemType = "Weapon";
        finishedBuilding = true;
    }
}
