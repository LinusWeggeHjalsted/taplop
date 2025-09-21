using UnityEngine;

public class LevelScript : MonoBehaviour
{
    public string levelName;
    // remember to set this on instantiation

    public bool HasName()
    {
        return !string.IsNullOrEmpty(levelName);
    }
}
