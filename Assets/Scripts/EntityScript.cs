using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class EntityScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject gear;
    public GearScript gearScript;
    public Transform mainHand;
    public Transform offHand;
    public GameObject mainHandWeapon;
    public GameObject offHandWeapon;
    public GameObject healthBar;
    public SpriteRenderer healthBarRenderer;
    public Sprite[] healthBarStates = new Sprite[8];
    public Sprite hitSprite;

    public string currentBuildTemplate = "00000000";
    public int speed = 1;
    public int maxHealth = 10;
    public int currentHealth = 10;
    public int armor = 0;
    public Vector3 previousPosition = new Vector3();
    public int unlockedSkills = 2;

    public List<GameObject> equippedSkills = new List<GameObject>();
    
    public void DisplayHit()
    {
        GameObject hitObject = new GameObject("Hit Sprite Object");
        hitObject.transform.parent = this.transform;
        hitObject.transform.localPosition = new Vector3(0, 0.3f, 0);
        SpriteRenderer hitRenderer = hitObject.AddComponent<SpriteRenderer>();
        hitRenderer.sortingLayerName = "Effects";
        hitRenderer.sortingOrder = 2;
        hitRenderer.sprite = hitSprite;
        Destroy(hitObject, 0.5f);
        Debug.Log("displayed and destroyed hit sprite");
    }

    public void DisplayHealth()
    {
        if (healthBar == null)
        {
            healthBar = new GameObject("Entity Health Bar");
            healthBar.transform.parent = this.transform;
            healthBar.transform.localPosition = new Vector3(0, 1.5f, 0);
            healthBarRenderer = healthBar.AddComponent<SpriteRenderer>();
            healthBarRenderer.sortingLayerName = "Effects";
            healthBarRenderer.sortingOrder = 2;
        }
        Sprite healthBarSprite = null;
        float healthPercentage = (float)currentHealth / (float)maxHealth;
        switch (healthPercentage)
        {
            case < 0.125f:
                healthBarSprite = healthBarStates[0];
                break;
            case >= 0.125f and < 0.250f:
                healthBarSprite = healthBarStates[1];
                break;
            case >= 0.250f and < 0.375f:
                healthBarSprite = healthBarStates[2];
                break;
            case >= 0.375f and < 0.500f:
                healthBarSprite = healthBarStates[3];
                break;
            case >= 0.500f and < 0.625f:
                healthBarSprite = healthBarStates[4];
                break;
            case >= 0.625f and < 0.750f:
                healthBarSprite = healthBarStates[5];
                break;
            case >= 0.750f and < 0.875f:
                healthBarSprite = healthBarStates[6];
                break;
            case >= 0.875f and < 1:
                healthBarSprite = healthBarStates[7];
                break;
            case >= 1:
                healthBarSprite = healthBarStates[8];
                break;
        }
        if (healthBarSprite != null)
        {
            healthBarRenderer.sprite = healthBarSprite;
        }
    }

    public void IncomingDamage(int damage)
    {
        DisplayHit();
        // to-do - figure out a good damage calculation
        int actualDamage = damage - armor;
        if (actualDamage < 0)
        {
            actualDamage = 0;
        }
        currentHealth -= actualDamage;
    }

    IEnumerator WaitForGearBeforePopulating()
    {
        while (!gearScript.finishedBuilding)
        {
            yield return null;
        }
        mainHand = gear.transform.Find("Main Hand");
        offHand = gear.transform.Find("Off Hand");
        mainHandWeapon = mainHand.GetChild(0).gameObject;
        offHandWeapon = offHand.GetChild(0).gameObject;
        GameObject skill1 = mainHandWeapon.transform.GetChild(0).gameObject;
        GameObject skill2 = mainHandWeapon.transform.GetChild(1).gameObject;
        GameObject skill3 = offHandWeapon.transform.GetChild(0).gameObject;
        equippedSkills.Add(skill1);
        equippedSkills.Add(skill2);
        equippedSkills.Add(skill3);
        finishedBuilding = true;
    }

    void Start()
    {
        Debug.Log("Hello World - I'm " + this.name);
        gear = this.transform.Find("Gear").gameObject;
        gearScript = gear.GetComponent<GearScript>();
        hitSprite = Resources.Load<Sprite>("Hit");
        healthBarStates = Resources.LoadAll<Sprite>("EntityHealthBars");
        currentHealth = maxHealth;
        unlockedSkills = 2;
        StartCoroutine(WaitForGearBeforePopulating());
    }

    void Update()
    {
        DisplayHealth();
    }
}
